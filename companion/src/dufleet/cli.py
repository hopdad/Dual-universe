"""The companion's command line.

    dufleet cmd VERB [ARGS...] [--epoch E] [--cseq C]
        Prints a command line for the Lua chat, with its CRC. Without --cseq it uses the
        next number from a small state file, so repeated calls never reuse one.
    dufleet decode [FILE] [--xml]
        Decodes @@DUB lines from text pasted on stdin or a file into one JSON message per
        line. --xml reads the client's XML log: the <message> of each <record>, unescaped.

The service itself (hub, pump, transports) comes with ADR-0001.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

from dufleet import __version__
from dufleet.protocol import CommandError, Deframer, build_command
from dufleet.router import VALIDATORS

DEFAULT_STATE = Path.home() / ".dufleet" / "manual-commands.json"
MESSAGE = re.compile(r"<message>(.*?)</message>", re.S)


def _load(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def cmd(args: argparse.Namespace) -> int:
    state = _load(args.state)
    epoch = args.epoch or state.get("epoch", 1)
    cseq = args.cseq or (state.get("next", 1) if epoch == state.get("epoch", 1) else 1)
    try:
        line = build_command(epoch, cseq, args.verb, *args.args)
    except CommandError as exc:
        print(f"{exc.code}: {exc.message}", file=sys.stderr)
        return 2
    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(json.dumps({"epoch": epoch, "next": cseq + 1}) + "\n", encoding="utf-8")
    print(line)
    return 0


def decode(args: argparse.Namespace) -> int:
    deframer = Deframer(clock=lambda: 0.0)  # a file has no timing: keep every partial message
    source = args.file.open(encoding="utf-8", errors="replace") if args.file else sys.stdin
    with source:
        if args.xml:
            lines = (html.unescape(m.group(1)) for m in MESSAGE.finditer(source.read()))
        else:
            lines = (raw.rstrip("\r\n") for raw in source)
        for line in lines:
            msg = deframer.feed(line)
            if msg is not None:
                out = {"bot": msg.bot, "kind": msg.kind, "seq": msg.seq, "body": msg.body}
                if not VALIDATORS[msg.kind].is_valid(msg.body):
                    out["valid"] = False
                print(json.dumps(out, ensure_ascii=False))
    if deframer.dropped or deframer.pending or deframer.duplicates:
        print(f"dropped {dict(deframer.dropped)}, incomplete {len(deframer.pending)}, "
              f"duplicates {deframer.duplicates}", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dufleet", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("cmd", help="print a /b command line for the Lua chat")
    p.add_argument("verb")
    p.add_argument("args", nargs="*")
    p.add_argument("--epoch", type=int, help="default: the one from the state file, else 1")
    p.add_argument("--cseq", type=int, help="default: the next one from the state file")
    p.add_argument("--state", type=Path, default=DEFAULT_STATE, help=f"counter file (default {DEFAULT_STATE})")
    p.set_defaults(func=cmd)

    p = sub.add_parser("decode", help="decode @@DUB lines into JSON messages")
    p.add_argument("file", nargs="?", type=Path, help="default: stdin")
    p.add_argument("--xml", action="store_true", help="unescape XML entities (the client's log file)")
    p.set_defaults(func=decode)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
