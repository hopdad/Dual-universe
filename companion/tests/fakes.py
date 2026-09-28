"""Test doubles: an in-memory hub with the same rules as supabase/migrations/0003_rpc.sql,
and a bus built from the reference codec, with knobs for losing and damaging lines."""

from __future__ import annotations

import asyncio
import json
from collections import Counter
from collections.abc import Awaitable, Callable
from typing import Any

from dufleet.hub import BotReport, CommandRow
from dufleet.protocol import CommandError, decide, encode_frame, parse_command

MOVES = {
    "claimed": {"sent", "acked", "done", "failed", "failed_delivery"},
    "sent": {"acked", "done", "failed", "failed_delivery"},
    "acked": {"done", "failed"},
}


class FakeHub:
    def __init__(self, bot_id: str = "bot-1"):
        self.bot_id = bot_id
        self.epoch, self.next = 1, 1
        self.commands: list[dict[str, Any]] = []
        self.log: list[tuple[int, str]] = []  # (cseq, status) in the order they were recorded
        self.states: list[dict] = []
        self.telemetry: list[dict] = []
        self.events: list[tuple[str, int, dict]] = []
        self.reports: list[BotReport] = []
        self.syncs: list[tuple[int, int]] = []
        self.now = 0.0  # the lease clock, advanced by tests

    def queue(self, verb: str, *args: str) -> dict[str, Any]:
        row = {"id": f"cmd-{self.epoch}-{self.next}", "bot_id": self.bot_id, "epoch": self.epoch, "cseq": self.next,
               "verb": verb, "args": list(args), "status": "queued", "attempts": 0, "claimed_at": None,
               "job_id": args[1] if verb == "run" and len(args) >= 2 else None, "error": None, "result": None,
               "created_by": "user"}
        self.next += 1
        self.commands.append(row)
        return row

    def status(self, cseq: int, epoch: int = 1) -> str:
        return next(r["status"] for r in self.commands if (r["epoch"], r["cseq"]) == (epoch, cseq))

    def row(self, cseq: int, epoch: int = 1) -> dict[str, Any]:
        return next(r for r in self.commands if (r["epoch"], r["cseq"]) == (epoch, cseq))

    def _inflight(self) -> list[dict[str, Any]]:
        rows = [r for r in self.commands if r["status"] in ("claimed", "sent")]
        return sorted(rows, key=lambda r: (r["epoch"], r["cseq"]))

    def _lease(self, row: dict[str, Any]) -> CommandRow:
        row["claimed_at"] = self.now
        row["attempts"] += 1
        return CommandRow.from_row(row)

    async def recover_inflight(self, bot_id: str) -> CommandRow | None:
        rows = self._inflight()
        return self._lease(rows[0]) if rows else None

    async def claim_next_command(self, bot_id: str, lease_s: int) -> CommandRow | None:
        rows = self._inflight()
        if rows:
            if self.now - rows[0]["claimed_at"] >= lease_s:
                return self._lease(rows[0])
            return None
        queued = sorted((r for r in self.commands if r["status"] == "queued"), key=lambda r: (r["epoch"], r["cseq"]))
        if not queued:
            return None
        queued[0]["status"] = "claimed"
        return self._lease(queued[0])

    async def command_progress(self, command_id, status, error=None, result=None) -> None:
        row = next(r for r in self.commands if r["id"] == command_id)
        if row["status"] == status:
            return
        if status not in MOVES.get(row["status"], set()):
            raise ValueError(f"command {row['cseq']} cannot go from {row['status']} to {status}")
        row["status"] = status
        row["error"] = error or row["error"]
        row["result"] = result if result is not None else row["result"]
        self.log.append((row["cseq"], status))

    async def acked_command_for_job(self, bot_id: str, job_id: str) -> str | None:
        rows = [r for r in self.commands if r["job_id"] == job_id and r["status"] == "acked"]
        return rows[-1]["id"] if rows else None

    async def acked_jobs(self, bot_id: str) -> list[tuple[str, str]]:
        return [(r["id"], r["job_id"]) for r in self.commands if r["verb"] == "run" and r["status"] == "acked"]

    async def request_resend(self, bot_id: str, from_seq: int) -> None:
        for r in self.commands:
            if r["verb"] == "resend" and r["status"] == "queued" and int(r["args"][0]) <= from_seq:
                return
        self.queue("resend", str(from_seq))["created_by"] = "companion"

    async def sync_epoch(self, bot_id: str, epoch: int, cseq: int) -> int:
        self.syncs.append((epoch, cseq))
        if epoch > self.epoch or (epoch == self.epoch and cseq >= self.next):
            self.epoch, self.next = max(self.epoch, epoch) + 1, 1
            for r in self.commands:
                if r["status"] == "queued" and r["epoch"] < self.epoch:
                    r["status"], r["error"] = "cancelled", "epoch changed"
        return self.epoch

    async def bot_report(self, bot_id: str, report: BotReport) -> None:
        self.reports.append(report)

    async def upsert_state(self, bot_id: str, state: dict) -> None:
        self.states.append(state)

    async def insert_telemetry(self, bot_id: str, data: dict) -> None:
        self.telemetry.append(data)

    async def insert_event(self, bot_id: str, kind: str, severity: int, data: dict) -> None:
        self.events.append((kind, severity, data))


Handler = Callable[[Any], tuple]  # (kind, fields) or (kind, fields, follow-up)


class FakeBus:
    """What the in-game bus does with a command line, from the Python reference codec."""

    def __init__(self, bot: str = "b1", reply_delay: float = 0.0):
        self.bot = bot
        self.reply_delay = reply_delay
        self.deliver: Callable[[str], Awaitable[None]] | None = None  # where frames go (the router's feed)
        self.epoch, self.cseq, self.reply = 0, 0, None
        self.executed: list[tuple[int, int, str]] = []
        self.received: list[str] = []
        self.seq = 0
        self.lose_lines = 0  # lines lost before they reach the bus
        self.lose_replies = 0  # A and N frames lost on the way back
        self.lose_kinds: Counter[str] = Counter()  # frames of these kinds lost on the way back, once each
        self.damage_lines = 0  # lines that arrive garbled
        self.ring: list[tuple[int, str, dict]] = []  # sent A, N, E and R frames, for resend
        self.handlers: dict[str, Handler] = {
            "pause": lambda cmd: ("N", {"err": "E_BUSY", "msg": "skill goto running"}),
            "run": lambda cmd: ("A", {"job": cmd.named["job"]}),
            "db": lambda cmd: ("A", {"data": {"k": cmd.named["key"], "v": "42"}}),
            "resend": lambda cmd: ("A", {}, self._replayer(int(cmd.named["from"]))),
        }
        self._tasks: set[asyncio.Task] = set()

    def _replayer(self, start: int) -> Callable[[], Awaitable[None]]:
        """Sends the ring frames from seq `start` on again, with their seq, after the reply (as the bus does)."""
        frames = [f for f in self.ring if f[0] >= start]

        async def replay() -> None:
            for seq, kind, body in frames:
                await self.emit(kind, body, seq=seq)

        return replay

    async def send(self, line: str) -> None:
        """The pump's transport."""
        self.received.append(line)
        if self.lose_lines:
            self.lose_lines -= 1
            return
        if self.damage_lines:
            self.damage_lines -= 1
            line = line.replace(" ", "  ", 1)
        try:
            cmd = parse_command(line)
        except CommandError as exc:
            await self.emit("N", {"ref": exc.ref, "e": exc.epoch, "err": exc.code, "msg": exc.message})
            return
        outcome = decide(self.epoch, self.cseq, cmd.epoch, cmd.cseq)
        if outcome == "execute":
            kind, fields, *after = self.handlers.get(cmd.verb, lambda c: ("A", {}))(cmd)
            body = {**fields, "ref": cmd.cseq, "e": cmd.epoch}
            self.epoch, self.cseq, self.reply = cmd.epoch, cmd.cseq, (kind, body)
            self.executed.append((cmd.epoch, cmd.cseq, cmd.verb))
            await self.emit(kind, body)
            for follow_up in after:
                await follow_up()
        elif outcome == "replay":
            kind, body = self.reply
            await self.emit(kind, {**body, "dup": True})
        elif outcome == "stale":
            await self.emit("N", {"ref": cmd.cseq, "e": cmd.epoch, "err": "E_EPOCH"})
        else:
            await self.emit("N", {"ref": cmd.cseq, "e": cmd.epoch, "err": "E_STATE"})

    async def emit(self, kind: str, body: dict, seq: int | None = None) -> None:
        """Sends a frame to the companion, as the transport would carry it. A resent frame keeps its seq."""
        if seq is None:
            self.seq += 1
            seq = self.seq
            if kind in ("A", "N", "E", "R"):
                self.ring = [*self.ring, (seq, kind, body)][-32:]
        if kind in ("A", "N") and self.lose_replies:
            self.lose_replies -= 1
            return
        if self.lose_kinds[kind] > 0:
            self.lose_kinds[kind] -= 1
            return
        lines = encode_frame(self.bot, kind, seq, json.dumps(body, separators=(",", ":")))
        task = asyncio.get_running_loop().create_task(self._deliver(lines))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _deliver(self, lines: list[str]) -> None:
        if self.reply_delay:
            await asyncio.sleep(self.reply_delay)
        for line in lines:
            await self.deliver(line)


async def until(condition: Callable[[], bool], timeout: float = 3.0) -> None:
    """Waits until condition() is true, or fails the test."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not condition():
        if loop.time() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.005)
