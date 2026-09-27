"""The Hub interface over the real SQL functions (supabase/migrations), for tests.

Connects to plain PostgreSQL as a superuser, then acts as one signed-in user the way
PostgREST does: SET ROLE authenticated plus the JWT subject claim. Production uses the
Supabase client instead; both call the same RPCs.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from dufleet.hub import BotReport, CommandRow

ROOT = Path(__file__).resolve().parents[2]
DB = "dufleet_pump_test"
OWNER = "aaaaaaaa-0000-0000-0000-000000000001"
DEVICE = "dddddddd-0000-0000-0000-000000000003"
STATE_COLUMNS = ("wx", "wy", "wz", "body_id", "lat", "lon", "alt", "speed_kmh", "fuel", "cargo_ratio", "skill",
                 "skill_phase", "autopilot")


def create_database(name: str) -> None:
    """A fresh database with the platform stub and every migration applied (as supabase/tests/run.sh)."""
    create = f"create database {name} template template0 encoding 'UTF8'"
    subprocess.run(["psql", "-X", "-q", "-d", "postgres", "-c", f"drop database if exists {name}", "-c", create],
                   check=True, capture_output=True)
    files = [ROOT / "supabase" / "tests" / "00_platform_stub.sql",
             *sorted((ROOT / "supabase" / "migrations").glob("*.sql"))]
    for f in files:
        subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", name, "-f", str(f)], check=True,
                       capture_output=True)


async def connect_as(dbname: str, user_id: str) -> psycopg.AsyncConnection:
    conn = await psycopg.AsyncConnection.connect(dbname=dbname, autocommit=True, row_factory=dict_row)
    await conn.execute("select set_config('request.jwt.claim.sub', %s, false)", (user_id,))
    await conn.execute("set role authenticated")
    return conn


def _jsonb(value: Any) -> Any:
    return Jsonb(value) if isinstance(value, (dict, list)) else value


class PgHub:
    def __init__(self, conn: psycopg.AsyncConnection):
        self.conn = conn

    async def _one(self, sql: str, params: tuple) -> dict[str, Any] | None:
        cur = await self.conn.execute(sql, params)
        return await cur.fetchone()

    async def recover_inflight(self, bot_id: str) -> CommandRow | None:
        row = await self._one("select * from public.recover_inflight(%s)", (bot_id,))
        return CommandRow.from_row(row) if row else None

    async def claim_next_command(self, bot_id: str, lease_s: int) -> CommandRow | None:
        row = await self._one("select * from public.claim_next_command(%s, %s)", (bot_id, lease_s))
        return CommandRow.from_row(row) if row else None

    async def command_progress(self, command_id, status, error=None, result=None) -> None:
        await self.conn.execute("select public.command_progress(%s, %s, %s, %s)",
                                (command_id, status, error, _jsonb(result)))

    async def acked_command_for_job(self, bot_id: str, job_id: str) -> str | None:
        row = await self._one("select id from public.commands where bot_id = %s and job_id = %s and status = 'acked'"
                              " order by created_at desc limit 1", (bot_id, job_id))
        return str(row["id"]) if row else None

    async def sync_epoch(self, bot_id: str, epoch: int, cseq: int) -> int:
        row = await self._one("select public.sync_epoch(%s, %s, %s) as epoch", (bot_id, epoch, cseq))
        return row["epoch"]

    async def bot_report(self, bot_id: str, report: BotReport) -> None:
        await self.conn.execute("select public.bot_report(%s, %s, %s, %s, %s)", (
            bot_id, report.status, report.script_version, report.boot_id, report.archhud_version))

    async def upsert_state(self, bot_id: str, state: dict[str, Any]) -> None:
        cols = ["bot_id", *(c for c in STATE_COLUMNS if c in state)]
        values = [bot_id, *(_jsonb(state[c]) for c in cols[1:])]
        updates = ", ".join(f"{c} = excluded.{c}" for c in cols)
        await self.conn.execute(
            f"insert into public.bot_state ({', '.join(cols)}) values ({', '.join(['%s'] * len(cols))})"
            f" on conflict (bot_id) do update set {updates}", values)

    async def insert_telemetry(self, bot_id: str, data: dict[str, Any]) -> None:
        await self.conn.execute("insert into public.telemetry (bot_id, data) values (%s, %s)", (bot_id, Jsonb(data)))

    async def insert_event(self, bot_id: str, kind: str, severity: int, data: dict[str, Any]) -> None:
        await self.conn.execute("insert into public.events (bot_id, kind, severity, data) values (%s, %s, %s, %s)",
                                (bot_id, kind, severity, Jsonb(data)))


def prepare_database() -> str:
    """DB, freshly created, with the owner and device users that the Postgres tests sign in as."""
    create_database(DB)
    with psycopg.connect(dbname=DB, autocommit=True) as conn:
        conn.execute("insert into auth.users (id, email) values (%s, 'owner'), (%s, 'device')", (OWNER, DEVICE))
    return DB
