"""Spike S11: can the companion hand commands to Lua through a local file?

Writes autoconf/custom/dufleet/inbox.lua in the game's Lua folder every interval,
with an increasing seq and the host's UTC time. The probe re-requires the file
after clearing package.loaded and shows the last seq and the lag on its panel.
Each write goes to a temp file first and is then renamed over the old one, so the
game never reads a half-written file.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

from dufleet_probe.gamepaths import custom_dir, find_lua_dir
from dufleet_probe.kit import save_json


def inbox_path(lua_dir: Path) -> Path:
    return custom_dir(lua_dir) / "dufleet" / "inbox.lua"


def render(seq: int, t: float) -> str:
    return (
        "-- written by dufleet-probe (spike S11); safe to delete\n"
        f'return {{seq = {seq}, t = {t:.3f}, host = "probe"}}\n'
    )


def write_atomic(path: Path, text: str, retries: int = 25) -> int:
    """Returns how many times the rename had to be retried (the game may hold the file)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    for attempt in range(retries):
        try:
            os.replace(tmp, path)
            return attempt
        except PermissionError:
            time.sleep(0.02)
    raise PermissionError(f"could not replace {path}; is it locked?")


def run(args) -> int:
    lua = find_lua_dir(args.lua_dir)
    if lua is None:
        raise SystemExit("Game Lua folder not found; pass --lua-dir")
    path = inbox_path(lua)
    print(f"Writing {path} every {args.interval} s for {args.duration} s. Watch the probe panel's S11 line.")
    seq, retries, writes = 0, 0, []
    start = time.monotonic()
    try:
        while time.monotonic() - start < args.duration:
            seq += 1
            t = time.time()
            retries += write_atomic(path, render(seq, t))
            writes.append({"seq": seq, "t": round(t, 3)})
            print(f"  seq {seq}")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("stopped")
    if args.cleanup and path.exists():
        path.unlink()
    summary = {"path": str(path), "writes": seq, "rename_retries": retries, "first": writes[:1], "last": writes[-1:]}
    out = save_json(args.results, "s11_inbox_host.json", summary)
    print(f"Wrote seq 1..{seq}. Saved {out}. Now copy the probe panel's S11 line into the results.")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("inbox", help="S11: write the inbox file the probe re-reads")
    p.add_argument("--lua-dir", help="the game's data\\lua folder (default: detected)")
    p.add_argument("--interval", type=float, default=1.0)
    p.add_argument("--duration", type=float, default=120)
    p.add_argument("--cleanup", action="store_true", help="delete the inbox file at the end")
    p.set_defaults(func=run)
