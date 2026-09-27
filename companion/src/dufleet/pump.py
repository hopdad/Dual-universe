"""Delivers the hub's commands to one bot (docs/protocol.md, "Delivery, dedupe and epochs").

One command at a time: claim it, send its line, and wait for the A or N with the
same ref and epoch. Without a reply, send the same line again after 1, 3 and 8 s,
then give up with failed_delivery. The bus answers a repeat from its stored reply,
so a command never runs twice, even when this process restarts mid-delivery and
recover_inflight hands the command back.

A `run` command stays acked until the R frame for its job arrives. An R can overtake
its command's A: a job can end in the tick it starts, and after a bus restart the
"interrupted" R goes out before the replayed A. Such a result is held until the A is
recorded.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections import Counter
from collections.abc import Awaitable, Callable

from dufleet.hub import CommandRow, Hub
from dufleet.protocol import CommandError, Message, build_command
from dufleet.protocol import generated as g

log = logging.getLogger(__name__)

Send = Callable[[str], Awaitable[None]]


def error_text(body: dict) -> str:
    err, msg = body.get("err", "E_INTERNAL"), body.get("msg")
    return f"{err}: {msg}" if msg else str(err)


def job_of(cmd: CommandRow) -> str | None:
    """The job a `run` command starts: its second argument, as the bus sees it."""
    if cmd.verb == "run" and len(cmd.args) >= 2:
        return cmd.args[1]
    return None


class CommandPump:
    def __init__(
        self,
        hub: Hub,
        bot_id: str,
        send: Send,
        *,
        transport: str = "C",
        lease_s: int = 60,
        poll_s: float = 2.0,
        ack_timeout: float | None = None,
        backoff: tuple[float, ...] | None = None,
    ):
        self.hub = hub
        self.bot_id = bot_id
        self.send = send
        self.lease_s = lease_s
        self.poll_s = poll_s
        self.ack_timeout = g.ACK_TIMEOUT_S[transport] if ack_timeout is None else ack_timeout
        self.backoff = tuple(g.RETRY_BACKOFF_S if backoff is None else backoff)
        self.stats: Counter[str] = Counter()
        self._replies: asyncio.Queue[Message] = asyncio.Queue()
        self._wake = asyncio.Event()
        self._jobs: dict[str, str] = {}
        self._held: dict[str, Message] = {}  # results that came before their command's A

    def on_reply(self, msg: Message) -> None:
        """A or N frames from the router."""
        self._replies.put_nowait(msg)

    def wake(self) -> None:
        """Called when the hub announces a new command (realtime), to skip the poll wait."""
        self._wake.set()

    async def run(self) -> None:
        """Delivers commands until cancelled. Hub or transport errors are logged and retried: a
        command left claimed or sent is handed out again, and the bus answers repeats."""
        recovered = False
        while True:
            self._wake.clear()
            try:
                cmd = None
                if not recovered:
                    cmd = await self.hub.recover_inflight(self.bot_id)
                    recovered = True
                    if cmd:
                        log.info("resuming command %s.%s after a restart", cmd.epoch, cmd.cseq)
                cmd = cmd or await self.hub.claim_next_command(self.bot_id, self.lease_s)
                if cmd is not None:
                    await self.deliver(cmd)
                    continue
            except Exception:
                self.stats["errors"] += 1
                log.exception("command pump error; retrying")
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._wake.wait(), self.poll_s)

    async def deliver(self, cmd: CommandRow) -> str:
        """Sends one command until it is answered or the retries run out. Returns its new status."""
        try:
            line = build_command(cmd.epoch, cmd.cseq, cmd.verb, *cmd.args)
        except CommandError as exc:
            await self.hub.command_progress(cmd.id, "failed", error=f"{exc.code}: {exc.message}")
            return "failed"
        delays = (0.0, *self.backoff)
        for attempt, delay in enumerate(delays, 1):
            if delay:
                self.stats["retries"] += 1
                await asyncio.sleep(delay)
            await self.send(line)
            self.stats["sent"] += 1
            if attempt == 1:
                await self.hub.command_progress(cmd.id, "sent")
            reply = await self._reply_for(cmd)
            if reply is None:
                continue
            if reply.kind == "A":
                await self.hub.command_progress(cmd.id, "acked")
                job = job_of(cmd)
                if job:
                    held = self._held.pop(job, None)
                    if held is not None:
                        return await self._finish(cmd.id, held)
                    self._jobs[job] = cmd.id
                    return "acked"
                await self.hub.command_progress(cmd.id, "done", result=reply.body.get("data"))
                return "done"
            await self.hub.command_progress(cmd.id, "failed", error=error_text(reply.body))
            return "failed"
        await self.hub.command_progress(cmd.id, "failed_delivery", error=f"no reply after {len(delays)} attempts")
        return "failed_delivery"

    async def _reply_for(self, cmd: CommandRow) -> Message | None:
        """The reply to cmd within the ack timeout. None on timeout, or when the bus reports the
        line arrived damaged (E_PARSE, ref 0): both mean "send it again"."""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.ack_timeout
        while (remaining := deadline - loop.time()) > 0:
            try:
                msg = await asyncio.wait_for(self._replies.get(), remaining)
            except TimeoutError:
                return None
            ref, epoch = msg.body.get("ref"), msg.body.get("e")
            if msg.kind == "N" and ref == 0 and msg.body.get("err") == "E_PARSE":
                self.stats["damaged"] += 1
                return None
            if ref == cmd.cseq and epoch == cmd.epoch:
                return msg
            self.stats["stray replies"] += 1
        return None

    async def on_result(self, msg: Message) -> None:
        """R frames from the router: finishes the command that started the job, now or once its
        A is recorded. Only the last 16 results without a command are held."""
        job = msg.body.get("job")
        command_id = self._jobs.pop(job, None) or await self.hub.acked_command_for_job(self.bot_id, job)
        command_id = command_id or self._jobs.pop(job, None)  # the A may have been recorded meanwhile
        if command_id is None:
            self.stats["held results"] += 1
            self._held[job] = msg
            while len(self._held) > 16:
                dropped = self._held.pop(next(iter(self._held)))
                self.stats["orphan results"] += 1
                log.warning("result for unknown job %s", dropped.body.get("job"))
            return
        await self._finish(command_id, msg)

    async def _finish(self, command_id: str, msg: Message) -> str:
        ok = msg.body.get("ok") is True
        status = "done" if ok else "failed"
        await self.hub.command_progress(command_id, status, error=None if ok else error_text(msg.body),
                                        result=msg.body.get("data"))
        return status
