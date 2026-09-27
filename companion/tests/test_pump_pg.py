"""The pump and router against the real hub SQL (supabase/migrations) on PostgreSQL.

Opt-in: set DUFLEET_PG_TESTS=1 and the libpq variables (PGHOST, PGPORT, PGUSER, PGPASSWORD)
for a server where the tests may create and drop the database dufleet_pump_test. CI does.
"""

import asyncio
import contextlib
import json
import os
import uuid

import pytest
from fakes import FakeBus
from pg_hub import PgHub, connect_as, create_database

from dufleet.protocol import encode_frame
from dufleet.pump import CommandPump
from dufleet.router import FrameRouter

pytestmark = pytest.mark.skipif(not os.environ.get("DUFLEET_PG_TESTS"), reason="set DUFLEET_PG_TESTS=1")

DB = "dufleet_pump_test"
OWNER = "aaaaaaaa-0000-0000-0000-000000000001"
DEVICE = "dddddddd-0000-0000-0000-000000000003"
FAST = {"ack_timeout": 0.25, "backoff": (0.01, 0.01, 0.01), "poll_s": 0.01}


@pytest.fixture(scope="module", autouse=True)
def database():
    create_database(DB)

    async def users():
        conn = await connect_as(DB, OWNER)
        await conn.execute("reset role")
        await conn.execute("insert into auth.users (id, email) values (%s, 'owner'), (%s, 'device')", (OWNER, DEVICE))
        await conn.close()

    asyncio.run(users())


class Rig:
    """One bot owned by OWNER, with DEVICE as its companion login."""

    async def open(self):
        self.owner = await connect_as(DB, OWNER)
        self.device = await connect_as(DB, DEVICE)
        cur = await self.owner.execute(
            "insert into public.bots (short_id, device_user_id) values (%s, %s) returning id",
            (f"b{uuid.uuid4().hex[:8]}", DEVICE))
        self.bot = str((await cur.fetchone())["id"])
        self.hub = PgHub(self.device)
        self.bus = FakeBus()
        self.restart()
        return self

    def restart(self):
        """A fresh companion process: new pump, router and deframer; same hub and game client."""
        self.pump = CommandPump(self.hub, self.bot, self.bus.send, **FAST)
        self.router = FrameRouter(self.hub, self.bot, self.pump)
        self.bus.deliver = self.router.feed

    async def queue(self, verb, *args):
        cur = await self.owner.execute("insert into public.commands (bot_id, verb, args) values (%s, %s, %s::jsonb)"
                                       " returning epoch, cseq", (self.bot, verb, json.dumps(list(args))))
        return await cur.fetchone()

    async def row(self, cseq, epoch=1):
        cur = await self.owner.execute("select * from public.commands where bot_id = %s and epoch = %s and cseq = %s",
                                       (self.bot, epoch, cseq))
        return await cur.fetchone()

    async def until_status(self, cseq, status, timeout=5.0):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while (await self.row(cseq))["status"] != status:
            if loop.time() > deadline:
                raise AssertionError(f"cseq {cseq} is {(await self.row(cseq))['status']}, not {status}")
            await asyncio.sleep(0.01)

    async def close(self):
        await self.owner.close()
        await self.device.close()


@contextlib.asynccontextmanager
async def running(pump):
    task = asyncio.create_task(pump.run())
    try:
        yield task
    finally:
        if task.done():
            task.result()  # the pump crashed: raise its error
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


async def wait_for(condition, task, timeout=5.0):
    """Waits for condition(); fails fast if the pump task has died."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not condition():
        if task.done():
            task.result()
            raise AssertionError("the pump stopped")
        if loop.time() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.005)


def test_ping_round_trip():
    async def main():
        r = await Rig().open()
        await r.queue("ping")
        async with running(r.pump):
            await r.until_status(1, "done")
        row = await r.row(1)
        assert row["attempts"] == 1 and row["sent_at"] and row["acked_at"] and row["finished_at"]
        await r.close()

    asyncio.run(main())


def test_a_restart_mid_delivery_runs_the_command_exactly_once():
    async def main():
        r = await Rig().open()
        r.bus.lose_replies = 1
        await r.queue("setid", "hauler-1")
        async with running(r.pump) as task:
            await wait_for(lambda: r.bus.executed, task)
        assert (await r.row(1))["status"] == "sent"
        r.restart()
        async with running(r.pump):
            await r.until_status(1, "done")
        assert r.bus.executed == [(1, 1, "setid")]
        assert (await r.row(1))["attempts"] == 2
        await r.close()

    asyncio.run(main())


def test_a_job_result_after_a_restart_finds_its_command():
    async def main():
        r = await Rig().open()
        await r.queue("run", "patrol", "j_p1")
        async with running(r.pump):
            await r.until_status(1, "acked")
        r.restart()
        await r.bus.emit("R", {"job": "j_p1", "skill": "patrol", "ok": True, "data": {"laps": 3}})
        await r.until_status(1, "done")
        assert (await r.row(1))["result"] == {"laps": 3}
        await r.close()

    asyncio.run(main())


def test_a_hello_ahead_of_the_hub_moves_it_to_a_new_epoch():
    async def main():
        r = await Rig().open()
        await r.queue("ping")
        hello = json.dumps({"boot": "k3f9a1", "v": "0.1.0", "epoch": 1, "cseq": 57})  # the bot is at 1.57
        for line in encode_frame("b1", "H", 1, hello):
            await r.router.feed(line)
        assert r.router.hub_epoch == 2
        assert (await r.row(1))["status"] == "cancelled"
        assert await r.queue("ping") == {"epoch": 2, "cseq": 1}
        cur = await r.owner.execute("select status, script_version, boot_id from public.bots where id = %s", (r.bot,))
        assert await cur.fetchone() == {"status": "ready", "script_version": "0.1.0", "boot_id": "k3f9a1"}
        await r.close()

    asyncio.run(main())


def test_a_command_the_bus_would_refuse_fails_without_sending():
    async def main():
        r = await Rig().open()
        await r.queue("run", "goto", "j_1", "p=::pos{0,2,1,2,3}")
        async with running(r.pump):
            await r.until_status(1, "failed")
        assert (await r.row(1))["error"].startswith("E_PARSE") and not r.bus.received
        await r.close()

    asyncio.run(main())


def test_state_telemetry_and_events_reach_the_owner():
    async def main():
        r = await Rig().open()
        t = '{"alt":285.5,"ap":"manual","st":"goto:travel","v":18,"w":[1,2,3]}'
        for kind, seq, body in (("T", 1, t), ("E", 2, '{"ev":"skill_state","to":"travel"}')):
            for line in encode_frame("b1", kind, seq, body):
                await r.router.feed(line)
        cur = await r.owner.execute("select wx, speed_kmh, skill, skill_phase, autopilot from public.bot_state")
        assert await cur.fetchone() == {"wx": 1, "speed_kmh": 18, "skill": "goto", "skill_phase": "travel",
                                        "autopilot": "manual"}
        cur = await r.owner.execute("select count(*) as n from public.telemetry where bot_id = %s", (r.bot,))
        assert (await cur.fetchone())["n"] == 1
        cur = await r.owner.execute("select kind, owner_id::text from public.events where bot_id = %s", (r.bot,))
        assert await cur.fetchall() == [{"kind": "skill_state", "owner_id": OWNER}]
        await r.close()

    asyncio.run(main())
