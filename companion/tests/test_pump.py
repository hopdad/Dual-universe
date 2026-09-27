import asyncio
import contextlib

from fakes import FakeBus, FakeHub, until

from dufleet.protocol import build_command, encode_frame
from dufleet.pump import CommandPump
from dufleet.router import FrameRouter

FAST = {"ack_timeout": 0.25, "backoff": (0.01, 0.01, 0.01), "poll_s": 0.01}


def rig(hub=None, bus=None):
    hub = hub or FakeHub()
    bus = bus or FakeBus()
    pump = CommandPump(hub, hub.bot_id, bus.send, **FAST)
    bus.deliver = FrameRouter(hub, hub.bot_id, pump).feed
    return hub, bus, pump


async def drive(pump, condition, timeout=3.0):
    task = asyncio.create_task(pump.run())
    try:
        await until(condition, timeout)
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


def test_ping_round_trip():
    async def main():
        hub, bus, pump = rig()
        hub.queue("ping")
        await drive(pump, lambda: hub.status(1) == "done")
        assert hub.log == [(1, "sent"), (1, "acked"), (1, "done")]
        assert bus.executed == [(1, 1, "ping")]
        assert bus.received == [build_command(1, 1, "ping")]

    asyncio.run(main())


def test_reply_data_becomes_the_result():
    async def main():
        hub, bus, pump = rig()
        hub.queue("db", "get", "dub.x")
        await drive(pump, lambda: hub.status(1) == "done")
        assert hub.row(1)["result"] == {"k": "dub.x", "v": "42"}

    asyncio.run(main())


def test_a_lost_line_is_sent_again():
    async def main():
        hub, bus, pump = rig()
        bus.lose_lines = 2
        hub.queue("ping")
        await drive(pump, lambda: hub.status(1) == "done")
        assert len(bus.received) == 3 and len(set(bus.received)) == 1
        assert bus.executed == [(1, 1, "ping")]
        assert hub.log.count((1, "sent")) == 1

    asyncio.run(main())


def test_a_lost_reply_is_answered_from_the_stored_reply():
    async def main():
        hub, bus, pump = rig()
        bus.lose_replies = 1
        hub.queue("ping")
        await drive(pump, lambda: hub.status(1) == "done")
        assert len(bus.received) == 2
        assert bus.executed == [(1, 1, "ping")]

    asyncio.run(main())


def test_gives_up_after_the_retries():
    async def main():
        hub, bus, pump = rig()
        bus.lose_lines = 100
        hub.queue("ping")
        await drive(pump, lambda: hub.status(1) == "failed_delivery")
        assert len(bus.received) == 4  # the first send and three retries
        assert hub.row(1)["error"] == "no reply after 4 attempts"

    asyncio.run(main())


def test_a_refusal_fails_the_command():
    async def main():
        hub, bus, pump = rig()
        hub.queue("pause")
        await drive(pump, lambda: hub.status(1) == "failed")
        assert hub.row(1)["error"] == "E_BUSY: skill goto running"
        assert len(bus.received) == 1

    asyncio.run(main())


def test_a_damaged_line_is_sent_again():
    async def main():
        hub, bus, pump = rig()
        bus.damage_lines = 1
        hub.queue("ping")
        await drive(pump, lambda: hub.status(1) == "done")
        assert pump.stats["damaged"] == 1
        assert len(bus.received) == 2

    asyncio.run(main())


def test_a_command_the_bus_would_refuse_is_failed_without_sending():
    async def main():
        hub, bus, pump = rig()
        hub.queue("run", "goto", "j_1", "p=::pos{0,2,1,2,3}")
        hub.queue("ping")
        await drive(pump, lambda: hub.status(2) == "done")
        assert hub.status(1) == "failed" and hub.row(1)["error"].startswith("E_PARSE")
        assert [line.split()[2] for line in bus.received] == ["ping"]

    asyncio.run(main())


def test_one_command_in_flight_at_a_time():
    async def main():
        hub, bus = FakeHub(), FakeBus(reply_delay=0.02)
        hub, bus, pump = rig(hub, bus)
        for _ in range(3):
            hub.queue("ping")
        await drive(pump, lambda: hub.status(3) == "done")
        assert [entry for entry in hub.log if entry[1] == "sent"] == [(1, "sent"), (2, "sent"), (3, "sent")]
        for cseq in (1, 2):
            assert hub.log.index((cseq, "done")) < hub.log.index((cseq + 1, "sent"))

    asyncio.run(main())


def test_stray_replies_are_ignored():
    async def main():
        hub, bus = FakeHub(), FakeBus(reply_delay=0.02)
        hub, bus, pump = rig(hub, bus)
        hub.queue("ping")
        task = asyncio.create_task(pump.run())
        await until(lambda: bus.received)
        for line in encode_frame("b1", "A", 99, '{"e":1,"ref":99}'):  # a late reply to an older command
            await bus.deliver(line)  # arrives before the real reply, which the bus delays
        await until(lambda: hub.status(1) == "done")
        task.cancel()
        assert pump.stats["stray replies"] == 1

    asyncio.run(main())


def test_a_job_finishes_with_its_result():
    async def main():
        hub, bus, pump = rig()
        hub.queue("run", "goto", "j_7a1", "pos=0,2,35.3951,104.1187,285.5413")
        task = asyncio.create_task(pump.run())
        await until(lambda: hub.status(1) == "acked")
        await bus.emit("R", {"job": "j_7a1", "skill": "goto", "ok": True, "data": {"dist": 3.2}})
        await until(lambda: hub.status(1) == "done")
        task.cancel()
        assert hub.row(1)["result"] == {"dist": 3.2}

    asyncio.run(main())


def test_a_failed_job_fails_its_command():
    async def main():
        hub, bus, pump = rig()
        hub.queue("run", "goto", "j_2")
        task = asyncio.create_task(pump.run())
        await until(lambda: hub.status(1) == "acked")
        await bus.emit("R", {"job": "j_2", "skill": "goto", "ok": False, "err": "E_FUEL", "msg": "atmo fuel 3%"})
        await until(lambda: hub.status(1) == "failed")
        task.cancel()
        assert hub.row(1)["error"] == "E_FUEL: atmo fuel 3%"

    asyncio.run(main())


def test_a_result_after_a_restart_still_finds_its_command():
    async def main():
        hub, bus, pump = rig()
        hub.queue("run", "patrol", "j_p1")
        await drive(pump, lambda: hub.status(1) == "acked")
        _, _, pump2 = rig(hub, bus)  # a new process: the pump has no memory of the job
        await bus.emit("R", {"job": "j_p1", "skill": "patrol", "ok": True})
        await until(lambda: hub.status(1) == "done")
        assert pump2.stats["orphan results"] == 0

    asyncio.run(main())


def test_a_restart_mid_delivery_runs_the_command_exactly_once():
    async def main():
        hub, bus, pump = rig()
        bus.lose_replies = 1  # the bus runs the command, but its ack never arrives
        hub.queue("setid", "hauler-1")
        task = asyncio.create_task(pump.run())
        await until(lambda: bus.executed)
        task.cancel()  # the companion dies before it hears back
        with contextlib.suppress(asyncio.CancelledError):
            await task
        assert hub.status(1) == "sent"

        _, _, pump2 = rig(hub, bus)  # the restarted companion
        await drive(pump2, lambda: hub.status(1) == "done")
        assert bus.executed == [(1, 1, "setid")]
        assert hub.row(1)["attempts"] == 2
        assert bus.received[0] == bus.received[1]

    asyncio.run(main())


def test_a_new_command_is_picked_up_as_soon_as_the_pump_is_woken():
    async def main():
        hub, bus = FakeHub(), FakeBus()
        pump = CommandPump(hub, hub.bot_id, bus.send, ack_timeout=0.05, backoff=(0.01,), poll_s=30)
        bus.deliver = FrameRouter(hub, hub.bot_id, pump).feed
        task = asyncio.create_task(pump.run())
        await asyncio.sleep(0.02)  # idle, waiting up to 30 s for work
        hub.queue("ping")
        pump.wake()
        await until(lambda: hub.status(1) == "done", timeout=1.0)
        task.cancel()

    asyncio.run(main())


class FlakyHub(FakeHub):
    """Fails the first two claims, as a hub behind a dropped connection would."""

    def __init__(self):
        super().__init__()
        self.failures = 2

    async def claim_next_command(self, bot_id, lease_s):
        if self.failures:
            self.failures -= 1
            raise ConnectionError("hub unreachable")
        return await super().claim_next_command(bot_id, lease_s)


def test_the_pump_rides_out_hub_errors():
    async def main():
        hub, bus, pump = rig(FlakyHub())
        hub.queue("ping")
        await drive(pump, lambda: hub.status(1) == "done")
        assert pump.stats["errors"] == 2

    asyncio.run(main())
