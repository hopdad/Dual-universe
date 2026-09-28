"""Routes the bus's frames: replies to the pump, everything else to the hub.

- A, N: the pump.
- H: sync_epoch and bot_report. A new boot id also drops the bot's partial messages.
- T: bot_state at most once per `state_every` seconds, a telemetry row every `telemetry_every`,
  and every T to the pump, which follows up jobs whose R frame may have been lost.
- E: an event named after `ev`. R: the pump, which finishes the job's command. D: a `bus_debug` event.

Bodies that do not match the protocol schema are dropped and counted.
"""

from __future__ import annotations

import logging
import time
from collections import Counter
from collections.abc import Callable
from typing import Any

from jsonschema import Draft202012Validator

from dufleet.hub import BotReport, Hub
from dufleet.protocol import Deframer, Message
from dufleet.protocol import generated as g
from dufleet.pump import CommandPump

log = logging.getLogger(__name__)

VALIDATORS = {
    kind: Draft202012Validator({"$defs": g.BODY_DEFS, "$ref": f"#/$defs/{name}"})
    for kind, name in g.KIND_BODIES.items()
}


def state_from_telemetry(body: dict[str, Any]) -> dict[str, Any]:
    """bot_state columns from a T body."""
    state: dict[str, Any] = {}
    if "w" in body:
        state["wx"], state["wy"], state["wz"] = body["w"]
    if "g" in body:
        state["lat"], state["lon"] = body["g"]
    for key, column in (("v", "speed_kmh"), ("alt", "alt"), ("b", "body_id"), ("fuel", "fuel"),
                        ("cargo", "cargo_ratio"), ("ap", "autopilot")):
        if key in body:
            state[column] = body[key]
    if "st" in body:
        skill, _, phase = body["st"].partition(":")
        state["skill"], state["skill_phase"] = skill, phase or None
    return state


class FrameRouter:
    def __init__(
        self,
        hub: Hub,
        bot_id: str,
        pump: CommandPump,
        deframer: Deframer | None = None,
        *,
        state_every: float = 1.0,
        telemetry_every: float = 5.0,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.hub = hub
        self.bot_id = bot_id
        self.pump = pump
        self.deframer = deframer or Deframer()
        self.state_every = state_every
        self.telemetry_every = telemetry_every
        self.clock = clock
        self.boot: str | None = None
        self.hub_epoch: int | None = None
        self.dropped: Counter[str] = Counter()
        self.errors = 0
        self._last_state: float | None = None
        self._last_telemetry: float | None = None

    async def feed(self, text: str) -> None:
        """One line from the outbound transport (a log line or a decoded optical frame). Never
        raises: a hub error is logged and counted in `errors`, and the transport keeps reading."""
        msg = self.deframer.feed(text)
        if msg is None:
            return
        try:
            await self.route(msg)
        except Exception:
            self.errors += 1
            log.exception("could not route %s frame %s", msg.kind, msg.seq)

    async def route(self, msg: Message) -> None:
        errors = list(VALIDATORS[msg.kind].iter_errors(msg.body))
        if errors:
            self.dropped[f"invalid {msg.kind}"] += 1
            log.warning("dropping %s frame %s: %s", msg.kind, msg.seq, errors[0].message)
            return
        if msg.kind in ("A", "N"):
            self.pump.on_reply(msg)
        elif msg.kind == "H":
            await self._hello(msg)
        elif msg.kind == "T":
            await self.pump.on_telemetry(msg.body)
            await self._telemetry(msg.body)
        elif msg.kind == "E":
            await self.hub.insert_event(self.bot_id, msg.body["ev"], 0, msg.body)
        elif msg.kind == "R":
            await self.pump.on_result(msg)
        elif msg.kind == "D":
            await self.hub.insert_event(self.bot_id, "bus_debug", 1, msg.body)

    async def _hello(self, msg: Message) -> None:
        body = msg.body
        if self.boot is not None and body["boot"] != self.boot:
            log.info("bus restarted (boot %s -> %s)", self.boot, body["boot"])
            self.deframer.forget(msg.bot)
            self.pump.on_new_boot()
        self.boot = body["boot"]
        self.hub_epoch = await self.hub.sync_epoch(self.bot_id, body["epoch"], body["cseq"])
        await self.hub.bot_report(self.bot_id, BotReport("ready", body["v"], body["boot"], body.get("ah")))

    async def _telemetry(self, body: dict[str, Any]) -> None:
        now = self.clock()
        if self._last_state is None or now - self._last_state >= self.state_every:
            self._last_state = now
            await self.hub.upsert_state(self.bot_id, state_from_telemetry(body))
        if self._last_telemetry is None or now - self._last_telemetry >= self.telemetry_every:
            self._last_telemetry = now
            await self.hub.insert_telemetry(self.bot_id, body)
