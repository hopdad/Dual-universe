"""Inbound commands: `/b <epoch>.<cseq> <verb> [args...] #<crc16>`.

The CRC covers the UTF-8 (in practice ASCII) bytes between "/b " and " #". Checks
run in a fixed order so that Lua and Python report the same error for a given
line; packages/protocol/vectors.json pins every case.

1. E_PARSE, ref 0: "/b " prefix, at most COMMAND_MAX chars, printable ASCII without
   '"' or '\\', a trailing " #XXXX" (uppercase hex), no other '#', no "::pos",
   single spaces between tokens, and a valid "<epoch>.<cseq>" header.
2. E_CRC: the CRC does not match.
3. E_VERB: the verb is not in the schema.
4. E_ARGS: the arguments do not fit the verb.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from dufleet.protocol import generated as g
from dufleet.protocol.crc import crc16

_ARG_TYPES = {name: re.compile(pattern) for name, pattern in g.ARG_TYPES.items()}
_SUFFIX = re.compile(r"(.*) #([0-9A-F]{4})", re.S)
_HEADER = re.compile(r"(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,9})")
_VERB = re.compile(r"[a-z]+")


class CommandError(ValueError):
    def __init__(self, code: str, message: str, ref: int = 0, epoch: int = 0):
        super().__init__(f"{code}: {message}")
        self.code, self.message, self.ref, self.epoch = code, message, ref, epoch


@dataclass(frozen=True)
class Command:
    epoch: int
    cseq: int
    verb: str
    args: tuple[str, ...]
    named: dict[str, str] = field(default_factory=dict, compare=False)
    params: dict[str, str] = field(default_factory=dict, compare=False)


def _raw_line(core: str) -> str:
    return f"{g.COMMAND_PREFIX}{core} #{crc16(core.encode('utf-8')):04X}"


def build_command(epoch: int, cseq: int, verb: str, *args: str) -> str:
    """A command line; raises CommandError if the result would not parse."""
    line = _raw_line(" ".join([f"{epoch}.{cseq}", verb, *args]))
    parse_command(line)
    return line


def _check_arg(value: str, spec: dict) -> bool:
    kind = spec["type"]
    if kind == "enum":
        return value in spec["values"]
    if kind == "skill":
        return value in g.SKILLS
    return bool(_ARG_TYPES[kind].fullmatch(value))


def parse_command(line: str) -> Command:
    if not line.startswith(g.COMMAND_PREFIX):
        raise CommandError("E_PARSE", "missing /b prefix")
    if len(line) > g.COMMAND_MAX:
        raise CommandError("E_PARSE", "line too long")
    if any(not 0x20 <= ord(ch) <= 0x7E for ch in line) or '"' in line or "\\" in line:
        raise CommandError("E_PARSE", "character not allowed")
    m = _SUFFIX.fullmatch(line[len(g.COMMAND_PREFIX):])
    if not m:
        raise CommandError("E_PARSE", "missing CRC")
    core, crc = m.group(1), int(m.group(2), 16)
    if "#" in core:
        raise CommandError("E_PARSE", "'#' inside the command")
    if "::pos" in line:
        raise CommandError("E_PARSE", "contains ::pos")
    tokens = core.split(" ")
    if len(tokens) < 2 or any(t == "" for t in tokens):
        raise CommandError("E_PARSE", "bad spacing")
    h = _HEADER.fullmatch(tokens[0])
    if not h:
        raise CommandError("E_PARSE", "bad header")
    epoch, cseq = int(h.group(1)), int(h.group(2))
    if not 1 <= epoch <= g.EPOCH_MAX or not 1 <= cseq <= g.CSEQ_MAX:
        raise CommandError("E_PARSE", "header out of range")
    if crc16(core.encode("utf-8")) != crc:
        raise CommandError("E_CRC", "CRC mismatch", cseq, epoch)
    verb = tokens[1]
    if not _VERB.fullmatch(verb) or verb not in g.VERBS:
        raise CommandError("E_VERB", f"unknown verb {verb[:20]}", cseq, epoch)
    args = tokens[2:]
    named: dict[str, str] = {}
    params: dict[str, str] = {}
    rest = list(args)
    for spec in g.VERBS[verb]["args"]:
        if spec.get("variadic"):
            for value in rest:
                if not _check_arg(value, spec):
                    raise CommandError("E_ARGS", f"bad {spec['name']}", cseq, epoch)
                key, _, val = value.partition("=")
                if key in params:
                    raise CommandError("E_ARGS", f"duplicate {key}", cseq, epoch)
                params[key] = val
            rest = []
            break
        if not rest:
            if spec.get("optional"):
                continue
            raise CommandError("E_ARGS", f"missing {spec['name']}", cseq, epoch)
        value = rest.pop(0)
        if not _check_arg(value, spec):
            raise CommandError("E_ARGS", f"bad {spec['name']}", cseq, epoch)
        named[spec["name"]] = value
    if rest:
        raise CommandError("E_ARGS", "too many arguments", cseq, epoch)
    if verb == "db" and (named["op"] == "set") != ("value" in named):
        raise CommandError("E_ARGS", "db set needs a value; get and del take none", cseq, epoch)
    return Command(epoch, cseq, verb, tuple(args), named, params)
