"""Reassembles frames from lines, drops corrupt ones, and counts what it dropped.

Lines can arrive more than once: the optical reader captures a frame on every pass
while it stays on screen, and a log tailer may re-read lines after a rotation. A
chunk identical to one of a message delivered in the last `ttl` seconds is counted
in `duplicates` and ignored, so feeding the same lines twice delivers each message
once. Chunks of a message that never completed are not remembered, so a `resend`
can fill the gap.
"""

from __future__ import annotations

import base64
import binascii
import json
import time
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, field

from dufleet.protocol import generated as g
from dufleet.protocol.frame import Chunk, FrameError, parse_frame_line


@dataclass
class Message:
    bot: str
    kind: str
    seq: int
    body: dict
    chunks: int = 1


@dataclass
class _Pending:
    started: float
    parts: dict[int, Chunk] = field(default_factory=dict)


class Deframer:
    def __init__(self, ttl: float = g.REASSEMBLY_TTL_S, clock: Callable[[], float] = time.monotonic):
        self.ttl = ttl
        self.clock = clock
        self.pending: dict[tuple[str, str, int, int], _Pending] = {}
        self.seen: dict[Chunk, float] = {}
        self.dropped: Counter[str] = Counter()
        self.duplicates = 0

    def feed(self, text: str) -> Message | None:
        """Returns a complete message when this line finishes one."""
        now = self.clock()
        self._expire(now)
        try:
            chunk = parse_frame_line(text)
        except FrameError as exc:
            if exc.reason != "no frame":
                self.dropped[exc.reason] += 1
            return None
        if chunk in self.seen:
            self.duplicates += 1
            return None
        if chunk.total == 1:
            self.seen[chunk] = now
            return self._message(chunk, chunk.body.encode("utf-8"), 1)
        key = (chunk.bot, chunk.kind, chunk.seq, chunk.total)
        entry = self.pending.setdefault(key, _Pending(now))
        entry.parts[chunk.index] = chunk
        if len(entry.parts) < chunk.total:
            return None
        del self.pending[key]
        for part in entry.parts.values():
            self.seen[part] = now
        joined = "".join(entry.parts[i].body for i in range(1, chunk.total + 1))
        try:
            data = base64.b64decode(joined, validate=True)
        except (binascii.Error, ValueError):
            self.dropped["bad base64"] += 1
            return None
        return self._message(chunk, data, chunk.total)

    def forget(self, bot: str) -> None:
        """Drops partial messages from a bot, e.g. when its H frame shows a new boot id."""
        for key in [k for k in self.pending if k[0] == bot]:
            del self.pending[key]

    def _message(self, chunk: Chunk, data: bytes, chunks: int) -> Message | None:
        try:
            body = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.dropped["bad json"] += 1
            return None
        if not isinstance(body, dict):
            self.dropped["body not an object"] += 1
            return None
        return Message(chunk.bot, chunk.kind, chunk.seq, body, chunks)

    def _expire(self, now: float) -> None:
        for key in [k for k, v in self.pending.items() if now - v.started > self.ttl]:
            del self.pending[key]
            self.dropped["incomplete"] += 1
        for chunk in [c for c, t in self.seen.items() if now - t > self.ttl]:
            del self.seen[chunk]
