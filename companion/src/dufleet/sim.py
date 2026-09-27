"""A virtual game client: the real Lua bus inside lua/tools/simulate.lua's fake ArchHUD.

For development and demos without the game. The companion types command lines into it
as chat input and reads its frames the way a transport would, while it ticks the bus
every 0.25 s. Needs lua5.3 with dkjson, and lua/tools/deps.sh run once.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
from collections.abc import Awaitable, Callable
from pathlib import Path

REPO = Path(os.environ.get("DUFLEET_REPO", Path(__file__).resolve().parents[3]))

OnLine = Callable[[str], Awaitable[None]]


class LuaSim:
    def __init__(self, on_line: OnLine | None = None, *, tick_s: float = 0.25, lua: str | None = None):
        self.on_line = on_line
        self.tick_s = tick_s
        self.lua = lua or shutil.which("lua5.3") or "lua5.3"
        self.proc: asyncio.subprocess.Process | None = None
        self.ticking = asyncio.Event()
        self.ticking.set()
        self._tasks: list[asyncio.Task] = []

    async def start(self) -> None:
        simulate = REPO / "lua" / "tools" / "simulate.lua"
        self.proc = await asyncio.create_subprocess_exec(
            self.lua, str(simulate), "--interactive",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        self._tasks = [asyncio.create_task(self._read()), asyncio.create_task(self._tick())]

    async def send(self, line: str) -> None:
        """Types a line into the Lua chat (Transport C, without the keyboard)."""
        await self._write(line)

    async def restart(self) -> None:
        """Leaves the seat and sits down again: a new bus start on the same databank."""
        await self._write("restart")

    def pause(self) -> None:
        """Stops the bus timer, so lines typed meanwhile wait unanswered."""
        self.ticking.clear()

    def resume(self) -> None:
        self.ticking.set()

    async def close(self) -> None:
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        if self.proc and self.proc.returncode is None:
            self.proc.stdin.close()
            await self.proc.wait()

    async def _write(self, text: str) -> None:
        self.proc.stdin.write((text + "\n").encode("utf-8"))
        await self.proc.stdin.drain()

    async def _tick(self) -> None:
        while True:
            await asyncio.sleep(self.tick_s)
            await self.ticking.wait()
            await self._write("tick 1")

    async def _read(self) -> None:
        while line := await self.proc.stdout.readline():
            if self.on_line is not None:
                await self.on_line(line.decode("utf-8", errors="replace").rstrip("\n"))
