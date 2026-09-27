"""Outbound frames: one line per chunk, `@@DUB|1|<bot>|<kind>|<seq>|<i>/<n>|<crc16>|<body>`.

A body that fits in one line is the JSON text itself. A longer body is base64 of
its UTF-8 bytes, split into n chunks. maxline counts UTF-8 bytes. The chunk count is
the smallest n >= 2 for which n chunks fit, sizing every header as if its index had
as many digits as n. Parsers split at most 7 times, because JSON may contain "|".
"""

from __future__ import annotations

import base64
import re
from dataclasses import dataclass

from dufleet.protocol import generated as g
from dufleet.protocol.crc import crc16

_BOT = re.compile(g.ARG_TYPES["bot"])
_UINT = re.compile(r"0|[1-9][0-9]{0,9}")
_INDEX = re.compile(r"([1-9][0-9]{0,1})/([1-9][0-9]{0,1})")
_CRC = re.compile(r"[0-9A-F]{4}")


class FrameError(ValueError):
    def __init__(self, reason: str, detail: str = ""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason


@dataclass(frozen=True)
class Chunk:
    bot: str
    kind: str
    seq: int
    index: int
    total: int
    body: str


def _header(bot: str, kind: str, seq: int, index: int, total: int, crc: int) -> str:
    return f"{g.PREFIX}|{g.VERSION}|{bot}|{kind}|{seq}|{index}/{total}|{crc:04X}|"


def encode_frame(bot: str, kind: str, seq: int, body_json: str, maxline: int = g.MAXLINE_DEFAULT) -> list[str]:
    """The lines for one frame. body_json is the already encoded JSON body."""
    if not _BOT.fullmatch(bot):
        raise FrameError("bad bot id", bot)
    if kind not in g.KINDS:
        raise FrameError("unknown kind", kind)
    if not 0 <= seq <= g.SEQ_MAX:
        raise FrameError("seq out of range", str(seq))
    data = body_json.encode("utf-8")
    single = _header(bot, kind, seq, 1, 1, crc16(data)) + body_json
    if len(single.encode("utf-8")) <= maxline:
        return [single]
    b64 = base64.b64encode(data).decode("ascii")
    total = 2
    while True:
        size = maxline - len(_header(bot, kind, seq, total, total, 0))
        if size < g.MIN_CHUNK:
            raise FrameError("maxline too small", str(maxline))
        if total * size >= len(b64):
            break
        total += 1
        if total > g.MAX_CHUNKS:
            raise FrameError("body too long", f"{len(data)} bytes")
    lines = []
    for i in range(total):
        part = b64[i * size:(i + 1) * size]
        lines.append(_header(bot, kind, seq, i + 1, total, crc16(part.encode("ascii"))) + part)
    return lines


def parse_frame_line(text: str) -> Chunk:
    """One chunk from a line that contains a frame, possibly after a prefix (e.g. a chat tag)."""
    start = text.find(g.PREFIX + "|")
    if start < 0:
        raise FrameError("no frame")
    parts = text[start:].rstrip("\r\n").split("|", 7)
    if len(parts) != 8:
        raise FrameError("too few fields")
    _, version, bot, kind, seq, index, crc, body = parts
    if version != str(g.VERSION):
        raise FrameError("unknown version", version)
    if not _BOT.fullmatch(bot):
        raise FrameError("bad bot id", bot)
    if kind not in g.KINDS:
        raise FrameError("unknown kind", kind)
    if not _UINT.fullmatch(seq) or int(seq) > g.SEQ_MAX:
        raise FrameError("bad seq", seq)
    m = _INDEX.fullmatch(index)
    if not m or not int(m.group(1)) <= int(m.group(2)) <= g.MAX_CHUNKS:
        raise FrameError("bad chunk index", index)
    if not _CRC.fullmatch(crc):
        raise FrameError("bad crc field", crc)
    if crc16(body.encode("utf-8")) != int(crc, 16):
        raise FrameError("crc mismatch")
    return Chunk(bot, kind, int(seq), int(m.group(1)), int(m.group(2)), body)
