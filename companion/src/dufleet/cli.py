"""The companion's command line.

    dufleet cmd VERB [ARGS...] [--epoch E] [--cseq C]
        Prints a command line for the Lua chat, with its CRC. Without --cseq it uses the
        next number from a small state file, so repeated calls never reuse one.
    dufleet decode [FILE] [--xml]
        Decodes @@DUB lines from text pasted on stdin or a file into one JSON message per
        line. --xml reads the client's XML log: the <message> of each <record>, unescaped.

    dufleet run [--config PATH]
        The companion for one bot: the hub, the pump and the router over the configured
        transport (dufleet/config.py describes the file; default ~/.dufleet/companion.toml).
    dufleet sim --bot BOT_UUID
        `run` with the simulator as the transport: the real Lua bus in a fake ArchHUD
        (lua/tools/simulate.lua), configured from the environment instead of a file.
        Set DUFLEET_SUPABASE_URL, DUFLEET_SUPABASE_KEY (publishable), DUFLEET_DEVICE_EMAIL
        and DUFLEET_DEVICE_PASSWORD.

    dufleet install [--archhud fetch|FOLDER|ZIP] [--atlas fetch|FILE] [--apply]
        Puts the bus (from lua/), and optionally ArchHUD and the atlas at their pinned
        versions, into the game's Lua folder. A dry run unless --apply; replaced files are
        backed up under autoconf/custom/_dufleet_backup/.
    dufleet doctor [--json]
        Checks the game folder: ArchHUD and the atlas against their pins, the bus against
        lua/. Exits 1 if a check fails.

The transports for real clients come with ADR-0001.
"""

from __future__ import annotations

import argparse
import asyncio
import html
import json
import logging
import os
import re
import sys
from dataclasses import asdict
from pathlib import Path

from dufleet import __version__, config, gamefiles
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


def _serve(cfg: config.Config) -> int:
    from dufleet.service import serve

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        asyncio.run(serve(cfg))
    except KeyboardInterrupt:
        pass
    except config.ConfigError as exc:
        print(exc, file=sys.stderr)
        return 2
    return 0


def run(args: argparse.Namespace) -> int:
    try:
        cfg = config.load(args.config)
    except config.ConfigError as exc:
        print(exc, file=sys.stderr)
        return 2
    return _serve(cfg)


def sim(args: argparse.Namespace) -> int:
    names = ("SUPABASE_URL", "SUPABASE_KEY", "DEVICE_EMAIL", "DEVICE_PASSWORD")
    missing = [f"DUFLEET_{k}" for k in names if not os.environ.get(f"DUFLEET_{k}")]
    if missing:
        print("set " + ", ".join(missing), file=sys.stderr)
        return 2
    try:
        cfg = config.parse({
            "hub": {"url": os.environ["DUFLEET_SUPABASE_URL"], "publishable_key": os.environ["DUFLEET_SUPABASE_KEY"],
                    "email": os.environ["DUFLEET_DEVICE_EMAIL"], "password_env": "DUFLEET_DEVICE_PASSWORD"},
            "bot": {"id": args.bot},
            "transport": {"kind": "sim"},
        })
    except config.ConfigError as exc:
        print(exc, file=sys.stderr)
        return 2
    print(f"virtual bot running for {args.bot}; Ctrl+C stops it", file=sys.stderr)
    return _serve(cfg)


def _warn(message: str) -> None:
    print("warning: " + message, file=sys.stderr)


def _print_checks(checks: list[gamefiles.Check]) -> None:
    for c in checks:
        print(f"{c.status:4}  {c.name:9}  {c.detail}")


def install(args: argparse.Namespace) -> int:
    lua = gamefiles.find_lua_dir(args.lua_dir)
    if lua is None or not gamefiles.custom_dir(lua).is_dir():
        where = gamefiles.custom_dir(lua) if lua else "the game's Lua folder"
        print(f"{where} not found; pass --lua-dir (the game's data\\lua folder) or set DUFLEET_GAME_DIR",
              file=sys.stderr)
        return 2
    files: dict[str, bytes] = {}
    try:
        if args.archhud:
            files.update(gamefiles.archhud_files(args.archhud, not args.no_verify, _warn))
        if args.atlas:
            files.update(gamefiles.atlas_file(args.atlas, not args.no_verify, _warn))
    except gamefiles.InstallError as exc:
        print(exc, file=sys.stderr)
        return 2
    if not args.no_bus:
        files.update(gamefiles.bus_files())
    if not files:
        print("nothing to install: --no-bus without --archhud or --atlas", file=sys.stderr)
        return 2
    report = gamefiles.install(gamefiles.custom_dir(lua), files, apply=args.apply)
    for key in ("written", "unchanged", "backed_up", "removed"):
        for rel in getattr(report, key):
            print(f"  {key.replace('_', ' '):10} {rel}")
    if not args.apply:
        print("Dry run: nothing was written. Add --apply to do it.")
        return 0
    if report.backup_dir:
        print(f"Replaced files were backed up to {report.backup_dir}")
    print()
    _print_checks(gamefiles.doctor(lua))
    return 0


def doctor(args: argparse.Namespace) -> int:
    checks = gamefiles.doctor(gamefiles.find_lua_dir(args.lua_dir))
    if args.json:
        print(json.dumps([asdict(c) for c in checks]))
    else:
        _print_checks(checks)
    return 1 if any(c.status == "fail" for c in checks) else 0


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

    p = sub.add_parser("run", help="run the companion for one bot (hub, pump and router over the transport)")
    p.add_argument("--config", type=Path, default=config.DEFAULT_PATH, help=f"default {config.DEFAULT_PATH}")
    p.set_defaults(func=run)

    p = sub.add_parser("sim", help="run a virtual bot (the real Lua bus without the game) against the hub")
    p.add_argument("--bot", required=True, help="the bot's id (uuid) in the hub")
    p.set_defaults(func=sim)

    p = sub.add_parser("install", help="put the bus, ArchHUD and the atlas into the game's Lua folder")
    p.add_argument("--lua-dir", help="the game's data\\lua folder (default: detected)")
    p.add_argument("--archhud", metavar="fetch|FOLDER|ZIP", help=f"also ArchHUD {gamefiles.pins.ARCHHUD_VERSION} "
                   "(pinned): download it, or take it from a checkout or a zip of the repository")
    p.add_argument("--atlas", metavar="fetch|FILE", help="also The Third Verse's atlas.lua (pinned)")
    p.add_argument("--no-bus", action="store_true", help="leave the bus out")
    p.add_argument("--no-verify", action="store_true", help="accept upstream files that do not match the pins")
    p.add_argument("--apply", action="store_true", help="write (default: show what would change)")
    p.set_defaults(func=install)

    p = sub.add_parser("doctor", help="check ArchHUD, the atlas and the bus in the game's Lua folder")
    p.add_argument("--lua-dir", help="the game's data\\lua folder (default: detected)")
    p.add_argument("--json", action="store_true", help="print the checks as JSON")
    p.set_defaults(func=doctor)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
