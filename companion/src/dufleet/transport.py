"""How lines travel between the companion and the in-game bus.

A transport hands every outbound line of the bus (frames, and noise the deframer skips) to
`on_line`, and delivers command lines to the bus. `letter` is its name in the protocol
(L, O, F or C), which sets the pump's ack timeout. ADR-0001 decides which real ones get
built (log tail or optical grid out; inbox file or chat keystrokes in); until then the only
one is the simulator.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Protocol

from dufleet.config import ConfigError, TransportConfig
from dufleet.sim import LuaSim

OnLine = Callable[[str], Awaitable[None]]


class Transport(Protocol):
    letter: str

    async def start(self, on_line: OnLine) -> None:
        """Starts delivering the bus's lines to on_line."""

    async def send(self, line: str) -> None:
        """Delivers one command line to the bus."""

    async def close(self) -> None: ...


class SimTransport:
    """The real Lua bus in its fake ArchHUD (dufleet.sim.LuaSim): command lines go in as chat."""

    letter = "C"

    def __init__(self, sim: LuaSim | None = None):
        self.sim = sim or LuaSim()

    async def start(self, on_line: OnLine) -> None:
        self.sim.on_line = on_line
        await self.sim.start()

    async def send(self, line: str) -> None:
        await self.sim.send(line)

    async def close(self) -> None:
        await self.sim.close()


def make_transport(cfg: TransportConfig) -> Transport:
    if cfg.kind == "sim":
        return SimTransport()
    raise ConfigError(f"transport {cfg.kind!r} is not built yet")
