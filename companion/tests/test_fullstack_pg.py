"""The whole chain without the game or HTTP: the hub SQL on PostgreSQL, the companion's pump
and router, and the real Lua bus in its fake ArchHUD (dufleet.sim.LuaSim).

Opt-in like test_pump_pg.py (DUFLEET_PG_TESTS=1), and needs lua5.3 and lua/tools/deps.sh.
"""

import asyncio
import contextlib
import json
import shutil
import uuid

import pytest
from conftest import ROOT
from pg_hub import DB, DEVICE, OWNER, PgHub, connect_as

from dufleet.pump import CommandPump
from dufleet.router import FrameRouter
from dufleet.sim import LuaSim

pytestmark = [
    pytest.mark.skipif(not (shutil.which("lua5.3") and (ROOT / "lua" / ".deps" / "du-mocks").is_dir()),
                       reason="needs lua5.3 and lua/tools/deps.sh"),
    pytest.mark.usefixtures("pg_database"),
]


class Chain:
    async def open(self):
        self.owner = await connect_as(DB, OWNER)
        self.device = await connect_as(DB, DEVICE)
        cur = await self.owner.execute(
            "insert into public.bots (short_id, device_user_id) values (%s, %s) returning id",
            (f"v{uuid.uuid4().hex[:8]}", DEVICE))
        self.bot = str((await cur.fetchone())["id"])
        self.hub = PgHub(self.device)
        self.sim = LuaSim()
        self.replies = []
        self.new_companion()
        await self.sim.start()
        return self

    def new_companion(self):
        """A companion process: pump, router and deframer, attached to the running game."""
        self.pump = CommandPump(self.hub, self.bot, self.sim.send, transport="C")
        self.router = FrameRouter(self.hub, self.bot, self.pump)
        spy = self.pump.on_reply

        def on_reply(msg):
            self.replies.append(msg.body)
            spy(msg)

        self.pump.on_reply = on_reply
        self.sim.on_line = self.router.feed

    async def queue(self, verb, *args):
        await self.owner.execute("insert into public.commands (bot_id, verb, args) values (%s, %s, %s::jsonb)",
                                 (self.bot, verb, json.dumps(list(args))))

    async def rows(self):
        cur = await self.owner.execute("select * from public.commands where bot_id = %s order by epoch, cseq",
                                       (self.bot,))
        return await cur.fetchall()

    async def until(self, condition, timeout=15.0):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while not await condition():
            if loop.time() > deadline:
                raise AssertionError(f"timed out; commands: {[(r['cseq'], r['status']) for r in await self.rows()]}")
            await asyncio.sleep(0.05)

    async def close(self):
        await self.sim.close()
        await self.owner.close()
        await self.device.close()


@contextlib.asynccontextmanager
async def running(pump):
    task = asyncio.create_task(pump.run())
    try:
        yield task
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


def test_commands_round_trip_through_the_real_bus():
    async def main():
        c = await Chain().open()
        for verb, *args in (("ping",), ("setid", "hauler-1"), ("status",)):
            await c.queue(verb, *args)

        async def all_done():
            rows = await c.rows()
            return len(rows) == 3 and all(r["status"] == "done" for r in rows)

        async with running(c.pump):
            await c.until(all_done)
        for row in await c.rows():
            took = (row["finished_at"] - row["created_at"]).total_seconds()
            assert took < 5, (row["verb"], took)  # the Phase 1 acceptance bound, without the game
        cur = await c.owner.execute("select status, script_version, archhud_version from public.bots where id = %s",
                                    (c.bot,))
        assert await cur.fetchone() == {"status": "ready", "script_version": "0.1.0", "archhud_version": "2.105"}
        cur = await c.owner.execute("select autopilot, speed_kmh from public.bot_state where bot_id = %s", (c.bot,))
        assert await cur.fetchone() == {"autopilot": "manual", "speed_kmh": 18}
        await c.close()

    asyncio.run(main())


def test_a_companion_restart_mid_command_runs_it_exactly_once():
    async def main():
        c = await Chain().open()
        await c.queue("db", "set", "dub.note", "first")
        c.sim.pause()  # the bus will not handle the line until the timer runs again
        async with running(c.pump):
            async def sent():
                return (await c.rows())[0]["status"] == "sent"

            await c.until(sent)
        # The first companion is gone. Its line reaches the bus now, and the bus runs it,
        # but nobody is listening for the ack.
        c.sim.resume()

        async def answered():
            return any(r.get("ref") == 1 and not r.get("dup") for r in c.replies)

        await c.until(answered)
        assert (await c.rows())[0]["status"] == "sent"

        c.new_companion()
        async with running(c.pump):
            async def done():
                return (await c.rows())[0]["status"] == "done"

            await c.until(done)
        row = (await c.rows())[0]
        assert row["attempts"] == 2
        assert [r for r in c.replies if r.get("ref") == 1][-1].get("dup") is True  # answered from the stored reply
        await c.close()

    asyncio.run(main())
