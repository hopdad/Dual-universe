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

An R can also be lost in transit. T frames name the job the bus is running, so a job
that T frames have not named for `idle_s` seconds has ended. The pump then asks for a
`resend` of the frames since the job's A (request_resend), and if the R still has not
come `lost_s` seconds later, fails the command as "result lost".
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections import Counter
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from dufleet.hub import CommandRow, Hub
from dufleet.protocol import CommandError, Message, build_command
from dufleet.protocol import generated as g

log = logging.getLogger(__name__)

Send = Callable[[str], Awaitable[None]]


def error_text(body: dict) -> str:
    err, msg = body.get("err", "E_INTERNAL"), body.get("msg")
    return f"{err}: {msg}" if msg else str(err)


@dataclass
class _Job:
    """A run command waiting for its job's R frame."""

    command_id: str
    ack_seq: int | None = None  # seq of the A, in the bus's current boot; None when unknown
    absent_since: float | None = None  # first T frame that did not name the job, since one did
    resend_at: float | None = None


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
        idle_s: float = 10.0,
        lost_s: float = 30.0,
        clock: Callable[[], float] = time.monotonic,
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
        self.idle_s = idle_s
        self.lost_s = lost_s
        self.clock = clock
        self._jobs: dict[str, _Job] = {}
        self._looked_up = False  # whether acked jobs from before this process are tracked yet
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
                    self._jobs[job] = _Job(cmd.id, reply.seq)
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
        tracked = self._jobs.pop(job, None)
        command_id = tracked.command_id if tracked else await self.hub.acked_command_for_job(self.bot_id, job)
        if command_id is None and job in self._jobs:  # the A was recorded meanwhile
            command_id = self._jobs.pop(job).command_id
        if command_id is None:
            self.stats["held results"] += 1
            self._held[job] = msg
            while len(self._held) > 16:
                dropped = self._held.pop(next(iter(self._held)))
                self.stats["orphan results"] += 1
                log.warning("result for unknown job %s", dropped.body.get("job"))
            return
        await self._finish(command_id, msg)

    async def on_telemetry(self, body: dict) -> None:
        """T frames from the router: follows up jobs whose R frame may have been lost."""
        now = self.clock()
        if not self._looked_up:  # jobs acked before this process started
            self._looked_up = True
            for command_id, job in await self.hub.acked_jobs(self.bot_id):
                self._jobs.setdefault(job, _Job(command_id))
        running = body.get("job")
        for job, entry in list(self._jobs.items()):
            if job == running:
                entry.absent_since = entry.resend_at = None
            elif entry.absent_since is None:
                entry.absent_since = now
            elif entry.resend_at is None and now - entry.absent_since >= self.idle_s:
                entry.resend_at = now
                start = 0 if entry.ack_seq is None else entry.ack_seq + 1
                log.info("job %s ended without its result; asking for frames from seq %d", job, start)
                self.stats["resend requests"] += 1
                await self.hub.request_resend(self.bot_id, start)
                self.wake()
            elif entry.resend_at is not None and now - entry.resend_at >= self.lost_s:
                del self._jobs[job]
                self.stats["lost results"] += 1
                log.warning("job %s: result lost", job)
                await self.hub.command_progress(entry.command_id, "failed",
                                                error="E_STATE: result lost; the bus no longer runs the job")

    def on_new_boot(self) -> None:
        """The bus restarted, so seqs start over: resends for tracked jobs start from 0."""
        for entry in self._jobs.values():
            entry.ack_seq = None

    async def _finish(self, command_id: str, msg: Message) -> str:
        ok = msg.body.get("ok") is True
        status = "done" if ok else "failed"
        await self.hub.command_progress(command_id, status, error=None if ok else error_text(msg.body),
                                        result=msg.body.get("data"))
        return status
