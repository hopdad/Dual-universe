"""The Hub on a Supabase project (supabase-py, async), signed in as the bot's device user.

Every write goes through the RPCs in supabase/migrations (0003_rpc.sql, 0006_resend.sql) or the tables row
level security opens to devices (bot_state, telemetry, events). Nothing here uses the
service role. Realtime inserts on `commands` wake the pump; its poll covers any
notification that is missed while the channel reconnects.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from postgrest.types import ReturnMethod
from realtime import AsyncRealtimeChannel, RealtimePostgresChangesListenEvent
from supabase import AsyncClient, acreate_client

from dufleet.hub import BotReport, CommandRow


class SupabaseHub:
    def __init__(self, client: AsyncClient):
        self.client = client

    @classmethod
    async def connect(cls, url: str, publishable_key: str, email: str, password: str) -> SupabaseHub:
        """Signs in as the device user. The client then sends that user's token to PostgREST and realtime."""
        client = await acreate_client(url, publishable_key)
        await client.auth.sign_in_with_password({"email": email, "password": password})
        return cls(client)

    async def _rpc(self, fn: str, params: dict[str, Any]) -> Any:
        return (await self.client.rpc(fn, params).execute()).data

    @staticmethod
    def _first(data: Any) -> CommandRow | None:
        rows = data if isinstance(data, list) else [data] if data else []
        return CommandRow.from_row(rows[0]) if rows else None

    async def recover_inflight(self, bot_id: str) -> CommandRow | None:
        return self._first(await self._rpc("recover_inflight", {"p_bot": bot_id}))

    async def claim_next_command(self, bot_id: str, lease_s: int) -> CommandRow | None:
        return self._first(await self._rpc("claim_next_command", {"p_bot": bot_id, "p_lease_s": lease_s}))

    async def command_progress(self, command_id, status, error=None, result=None) -> None:
        await self._rpc("command_progress", {"p_id": command_id, "p_status": status, "p_error": error,
                                             "p_result": result})

    async def acked_command_for_job(self, bot_id: str, job_id: str) -> str | None:
        res = await (self.client.table("commands").select("id").eq("bot_id", bot_id).eq("job_id", job_id)
                     .eq("status", "acked").order("created_at", desc=True).limit(1).execute())
        return str(res.data[0]["id"]) if res.data else None

    async def acked_jobs(self, bot_id: str) -> list[tuple[str, str]]:
        res = await (self.client.table("commands").select("id, job_id").eq("bot_id", bot_id).eq("verb", "run")
                     .eq("status", "acked").execute())
        return [(str(r["id"]), r["job_id"]) for r in res.data or [] if r.get("job_id")]

    async def request_resend(self, bot_id: str, from_seq: int) -> None:
        await self._rpc("request_resend", {"p_bot": bot_id, "p_from": from_seq})

    async def sync_epoch(self, bot_id: str, epoch: int, cseq: int) -> int:
        return int(await self._rpc("sync_epoch", {"p_bot": bot_id, "p_epoch": epoch, "p_cseq": cseq}))

    async def bot_report(self, bot_id: str, report: BotReport) -> None:
        await self._rpc("bot_report", {"p_bot": bot_id, "p_status": report.status,
                                       "p_script_version": report.script_version, "p_boot_id": report.boot_id,
                                       "p_archhud_version": report.archhud_version})

    async def upsert_state(self, bot_id: str, state: dict[str, Any]) -> None:
        await self.client.table("bot_state").upsert({"bot_id": bot_id, **state},
                                                    returning=ReturnMethod.minimal).execute()

    async def insert_telemetry(self, bot_id: str, data: dict[str, Any]) -> None:
        await self.client.table("telemetry").insert({"bot_id": bot_id, "data": data},
                                                    returning=ReturnMethod.minimal).execute()

    async def insert_event(self, bot_id: str, kind: str, severity: int, data: dict[str, Any]) -> None:
        await self.client.table("events").insert({"bot_id": bot_id, "kind": kind, "severity": severity,
                                                  "data": data}, returning=ReturnMethod.minimal).execute()

    async def watch_commands(self, bot_id: str, wake: Callable[[], None]) -> AsyncRealtimeChannel:
        """Calls wake() whenever a command is queued for this bot."""
        channel = self.client.channel(f"dufleet-commands-{bot_id}")
        channel.on_postgres_changes(RealtimePostgresChangesListenEvent.Insert, lambda _payload: wake(),
                                    table="commands", schema="public", filter=f"bot_id=eq.{bot_id}")
        await channel.subscribe()
        return channel
