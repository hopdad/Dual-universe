"""What the companion needs from the hub (supabase/migrations/0003_rpc.sql).

The pump and the frame router depend only on this interface, so they can run
against the Supabase client in production and against fakes or plain PostgreSQL
in tests.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol


@dataclass(frozen=True)
class CommandRow:
    id: str
    bot_id: str
    epoch: int
    cseq: int
    verb: str
    args: tuple[str, ...] = ()
    job_id: str | None = None
    status: str = "claimed"
    attempts: int = 1

    @classmethod
    def from_row(cls, row: dict[str, Any]) -> CommandRow:
        return cls(
            id=str(row["id"]),
            bot_id=str(row["bot_id"]),
            epoch=int(row["epoch"]),
            cseq=int(row["cseq"]),
            verb=str(row["verb"]),
            args=tuple(str(a) for a in row.get("args") or ()),
            job_id=row.get("job_id"),
            status=str(row.get("status", "claimed")),
            attempts=int(row.get("attempts", 1)),
        )


@dataclass
class BotReport:
    status: str
    script_version: str
    boot_id: str
    archhud_version: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)


class Hub(Protocol):
    async def recover_inflight(self, bot_id: str) -> CommandRow | None:
        """The command this bot had in flight, with a fresh lease, or None."""

    async def claim_next_command(self, bot_id: str, lease_s: int) -> CommandRow | None:
        """The next command to deliver, or None (nothing queued, or one still in flight)."""

    async def command_progress(
        self, command_id: str, status: str, error: str | None = None, result: dict | None = None
    ) -> None:
        """Records sent, acked, done, failed or failed_delivery. Repeating a status is a no-op."""

    async def acked_command_for_job(self, bot_id: str, job_id: str) -> str | None:
        """The id of the acked command that started this job, if any (for R frames after a restart)."""

    async def sync_epoch(self, bot_id: str, epoch: int, cseq: int) -> int:
        """Passes on the bus watermark from an H frame; returns the hub's epoch."""

    async def bot_report(self, bot_id: str, report: BotReport) -> None: ...

    async def upsert_state(self, bot_id: str, state: dict[str, Any]) -> None: ...

    async def insert_telemetry(self, bot_id: str, data: dict[str, Any]) -> None: ...

    async def insert_event(self, bot_id: str, kind: str, severity: int, data: dict[str, Any]) -> None: ...
