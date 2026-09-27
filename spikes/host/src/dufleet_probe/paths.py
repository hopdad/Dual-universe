"""Spike S8: where the client keeps its Lua files and logs, what runs, and what is installed."""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import time
from pathlib import Path

from dufleet_probe import pins
from dufleet_probe.gamepaths import candidate_game_dirs, candidate_log_dirs, custom_dir, find_lua_dir, newest_logs
from dufleet_probe.kit import IS_WINDOWS, LUA_SOURCE, PROBE_FILES, save_json, sha256_file


def writable(directory: Path) -> bool | None:
    if not directory.is_dir():
        return None
    marker = directory / ".dufleet-write-test"
    try:
        marker.write_bytes(b"")
        marker.unlink()
        return True
    except OSError:
        return False


def installed_state(custom: Path) -> dict:
    def state(rel: str, sha: str) -> str:
        path = custom / rel
        if not path.is_file():
            return "missing"
        return "pinned" if sha256_file(path) == sha else "different"

    archhud = {rel: state(rel, sha) for rel, sha in pins.ARCHHUD_FILES.values()}
    pinned = sum(v == "pinned" for v in archhud.values())
    return {
        "archhud": f"{pinned}/{len(archhud)} files match the pinned 2.105"
        if pinned == len(archhud) else {k: v for k, v in archhud.items() if v != "pinned"},
        "atlas": state(*pins.ATLAS_FILE),
        "probe": {rel: state(rel, sha256_file(LUA_SOURCE / rel)) for rel in PROBE_FILES},
        "inbox_file": (custom / "dufleet" / "inbox.lua").is_file(),
    }


def game_processes(lua: Path | None) -> list[dict]:
    try:
        import psutil
    except ImportError:
        return []
    game_root = str(lua.parents[1]).lower() if lua else None  # <game>\data\lua -> <game>
    found, procs = [], []
    for proc in psutil.process_iter(["pid", "name", "exe"]):
        name, exe = proc.info["name"] or "", proc.info["exe"] or ""
        if "dual" in name.lower() or (game_root and exe.lower().startswith(game_root)):
            entry = {"pid": proc.pid, "name": name, "exe": exe}
            try:
                entry["rss_mb"] = round(proc.memory_info().rss / 2**20)
                proc.cpu_percent(None)
                procs.append((entry, proc))
            except psutil.Error:
                pass
            found.append(entry)
    time.sleep(1.0)
    for entry, proc in procs:
        try:
            entry["cpu_pct"] = proc.cpu_percent(None)
        except psutil.Error:
            pass
    if IS_WINDOWS:
        from dufleet_probe import winapi

        for entry in found:
            entry["elevated"] = winapi.process_elevated(entry["pid"])
    return found


def equ8_hints() -> dict:
    hints: dict = {"processes": [], "services": [], "driver_files": []}
    try:
        import psutil

        hints["processes"] = sorted({p.info["name"] for p in psutil.process_iter(["name"])
                                     if p.info["name"] and "equ8" in p.info["name"].lower()})
    except Exception:
        pass
    if IS_WINDOWS:
        for kind in ("driver", "service"):
            try:
                out = subprocess.run(["sc", "query", "type=", kind, "state=", "all"],
                                     capture_output=True, text=True, timeout=30).stdout
            except (OSError, subprocess.SubprocessError):
                continue
            for line in out.splitlines():
                key, _, value = line.strip().partition(":")
                if key.strip() in ("SERVICE_NAME", "DISPLAY_NAME") and "equ8" in value.lower():
                    hints["services"].append(value.strip())
        drivers = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "drivers"
        try:
            hints["driver_files"] = sorted(p.name for p in drivers.glob("*equ8*"))
        except OSError:
            pass
    hints["found"] = any(hints[k] for k in ("processes", "services", "driver_files"))
    return hints


def monitors():
    try:
        import mss

        with mss.mss() as sct:
            return sct.monitors[1:]
    except Exception as exc:  # no display, missing library
        return f"unavailable: {exc}"


def run(args) -> int:
    lua = find_lua_dir(args.lua_dir)
    custom = custom_dir(lua) if lua else None
    log_dirs = candidate_log_dirs(args.log_dir)
    report = {
        "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "terminal_elevated": None,
        "game_dirs": [{"path": str(g), "exists": g.is_dir()} for g in candidate_game_dirs()],
        "lua_dir": str(lua) if lua else None,
        "custom_dir_writable": writable(custom) if custom else None,
        "installed": installed_state(custom) if custom and custom.is_dir() else None,
        "log_dirs": [str(d) for d in log_dirs],
        "newest_logs": [
            {"path": str(p), "kb": p.stat().st_size // 1024,
             "modified": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(p.stat().st_mtime))}
            for p in newest_logs(log_dirs)
        ],
        "game_processes": game_processes(lua),
        "equ8": equ8_hints(),
        "monitors": monitors(),
    }
    if IS_WINDOWS:
        from dufleet_probe import winapi

        report["terminal_elevated"] = winapi.is_admin()
        # `inject` finds the game by window title; record the real one.
        report["game_windows"] = [{"hwnd": h, "title": t, "pid": p}
                                  for h, t, p in winapi.find_windows(["dual", "mydu"])]
    path = save_json(args.results, "s8_paths.json", report)
    print(f"Lua folder:        {report['lua_dir'] or 'NOT FOUND (pass --lua-dir)'}")
    print(f"  writable:        {report['custom_dir_writable']}")
    print(f"  installed:       {report['installed']}")
    print(f"Newest logs:       {[log['path'] for log in report['newest_logs']] or 'none found (pass --log-dir)'}")
    print(f"Game processes:    {[(p['name'], p.get('rss_mb'), p.get('elevated')) for p in report['game_processes']]}")
    print(f"Game windows:      {[w['title'] for w in report.get('game_windows', [])] or 'none (or not Windows)'}")
    print(f"EQU8 traces:       {report['equ8']['found']}")
    print(f"Saved {path}")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("paths", help="S8: find the game's Lua folder, logs, processes and anti-cheat traces")
    p.add_argument("--lua-dir", help="the game's data\\lua folder (default: detected)")
    p.add_argument("--log-dir", help="folder holding the *.xml logs (default: detected)")
    p.set_defaults(func=run)
