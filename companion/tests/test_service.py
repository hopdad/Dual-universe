"""dufleet run's service loop, over a transport made from the reference bus, and over the simulator."""

import asyncio

from conftest import needs_lua_bus
from fakes import FakeBus, FakeHub, until

from dufleet import config
from dufleet.service import serve
from dufleet.transport import SimTransport

CFG = config.parse({
    "hub": {"url": "https://x.supabase.co", "publishable_key": "k", "email": "device@x"},
    "bot": {"id": "11111111-2222-3333-4444-555555555555"},
    "pump": {"poll_s": 0.05},
})


class BusTransport:
    letter = "C"

    def __init__(self, bus):
        self.bus, self.closed = bus, False

    async def start(self, on_line):
        self.bus.deliver = on_line

    async def send(self, line):
        await self.bus.send(line)

    async def close(self):
        self.closed = True


class RealtimeDownHub(FakeHub):
    async def watch_commands(self, bot_id, wake):
        raise ConnectionError("realtime unreachable")


def test_commands_flow_until_stopped():
    async def main():
        hub, bus, stop = RealtimeDownHub(bot_id=str(CFG.bot.id)), FakeBus(), asyncio.Event()
        transport = BusTransport(bus)
        task = asyncio.create_task(serve(CFG, hub=hub, transport=transport, stop=stop))
        hub.queue("ping")
        hub.queue("status")
        await until(lambda: hub.status(2) == "done")  # the pump polls when realtime is down
        stop.set()
        pump = await task
        assert transport.closed and pump.stats["sent"] == 2

    asyncio.run(main())


@needs_lua_bus
def test_the_simulator_is_a_transport():
    async def main():
        hub, stop = FakeHub(bot_id=str(CFG.bot.id)), asyncio.Event()
        task = asyncio.create_task(serve(CFG, hub=hub, transport=SimTransport(), stop=stop))
        hub.queue("setid", "hauler-1")
        await until(lambda: hub.status(1) == "done", timeout=10)
        await until(lambda: hub.states, timeout=10)  # T frames reach bot_state
        stop.set()
        await task
        assert hub.reports[-1].status == "ready"

    asyncio.run(main())
