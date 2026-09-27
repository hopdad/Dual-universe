"""The bot bus wire protocol, version 1 (docs/protocol.md).

Constants come from generated.py, which packages/protocol/codegen.py writes from
protocol.schema.json. The in-game bus implements the same rules in Lua; both are
tested against packages/protocol/vectors.json.
"""

from dufleet.protocol.command import Command, CommandError, build_command, parse_command
from dufleet.protocol.crc import crc16
from dufleet.protocol.dedupe import decide
from dufleet.protocol.deframer import Deframer, Message
from dufleet.protocol.frame import Chunk, FrameError, encode_frame, parse_frame_line

__all__ = [
    "Chunk", "Command", "CommandError", "Deframer", "FrameError", "Message",
    "build_command", "crc16", "decide", "encode_frame", "parse_command", "parse_frame_line",
]
