import asyncio
import json

from fakes import FakeHub

from dufleet.protocol import encode_frame
from dufleet.pump import CommandPump
from dufleet.router import FrameRouter, state_from_telemetry


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def lines(kind, seq, body, bot="b1", maxline=400):
    return encode_frame(bot, kind, seq, json.dumps(body, separators=(",", ":")), maxline)


def rig(clock=None):
    hub = FakeHub()

    async def send(line):
        pass

    pump = CommandPump(hub, hub.bot_id, send)
    return hub, FrameRouter(hub, hub.bot_id, pump, clock=clock or Clock())


async def feed(router, *frames):
    for frame in frames:
        for line in frame:
            await router.feed(line)


HELLO = {"boot": "k3f9a1", "v": "0.1.0", "epoch": 1, "cseq": 42, "id": "hauler-1", "ah": "2.105", "tr": "L",
         "ml": 400, "q": 0}


def test_hello_syncs_the_epoch_and_reports_the_bot():
    async def main():
        hub, router = rig()
        await feed(router, lines("H", 1, HELLO))
        assert hub.syncs == [(1, 42)]
        report = hub.reports[0]
        assert (report.status, report.script_version, report.boot_id, report.archhud_version) == \
            ("ready", "0.1.0", "k3f9a1", "2.105")
        assert router.hub_epoch == 2  # the bot's cseq 42 is ahead of this empty hub

    asyncio.run(main())


def test_a_new_boot_drops_partial_messages():
    async def main():
        hub, router = rig()
        await feed(router, lines("H", 1, HELLO))
        long_event = lines("E", 2, {"ev": "note", "data": {"text": "x" * 300}}, maxline=120)
        await router.feed(long_event[0])
        assert router.deframer.pending
        await feed(router, lines("H", 1, {**HELLO, "boot": "z9y8x7"}))
        assert not router.deframer.pending

    asyncio.run(main())


def test_telemetry_is_throttled():
    async def main():
        clock = Clock()
        hub, router = rig(clock)
        for seq, t in enumerate([0.0, 0.5, 1.0, 4.9, 5.0], 1):
            clock.now = t
            await feed(router, lines("T", seq, {"v": seq}))
        assert [s["speed_kmh"] for s in hub.states] == [1, 3, 4]  # 5.0 is only 0.1 s after 4.9
        assert [t["v"] for t in hub.telemetry] == [1, 5]

    asyncio.run(main())


def test_telemetry_maps_to_bot_state_columns():
    body = {"w": [1.5, 2.5, 3.5], "v": 18, "alt": 285.5, "b": 2, "g": [35.39, 104.11], "fuel": {"atmo": 0.8},
            "cargo": 0.4, "st": "goto:travel", "ap": "altitude_hold"}
    assert state_from_telemetry(body) == {
        "wx": 1.5, "wy": 2.5, "wz": 3.5, "lat": 35.39, "lon": 104.11, "speed_kmh": 18, "alt": 285.5, "body_id": 2,
        "fuel": {"atmo": 0.8}, "cargo_ratio": 0.4, "autopilot": "altitude_hold", "skill": "goto",
        "skill_phase": "travel",
    }
    assert state_from_telemetry({"st": "idle"}) == {"skill": "idle", "skill_phase": None}


def test_events_and_debug_frames_become_hub_events():
    async def main():
        hub, router = rig()
        await feed(router, lines("E", 1, {"ev": "skill_state", "skill": "goto", "to": "travel"}),
                   lines("D", 2, {"msg": "tick: sensor fault"}))
        assert hub.events == [("skill_state", 0, {"ev": "skill_state", "skill": "goto", "to": "travel"}),
                              ("bus_debug", 1, {"msg": "tick: sensor fault"})]

    asyncio.run(main())


def test_bodies_that_break_the_schema_are_dropped():
    async def main():
        hub, router = rig()
        await feed(router, lines("A", 1, {"ref": 1}), lines("T", 2, {"cargo": 2}), lines("H", 3, {"boot": "k3f9"}))
        assert router.dropped == {"invalid A": 1, "invalid T": 1, "invalid H": 1}
        assert not hub.states and not hub.syncs

    asyncio.run(main())


def test_hub_errors_are_counted_not_raised():
    async def main():
        hub, router = rig()

        async def broken(*args):
            raise ConnectionError("hub unreachable")

        hub.insert_event = broken
        await feed(router, lines("E", 1, {"ev": "x"}), lines("T", 2, {"v": 1}))
        assert router.errors == 1 and len(hub.states) == 1

    asyncio.run(main())
