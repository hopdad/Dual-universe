"""Where the myDU client keeps its Lua folder and its logs (spike S8 confirms both).

The myDU client installs under C:\\ProgramData\\My Dual Universe (ClientModManager
README); the official client used C:\\ProgramData\\Dual Universe. Logs were under
%LOCALAPPDATA%\\NQ\\DualUniverse\\log. Override with DUFLEET_GAME_DIR or
DUFLEET_LOG_DIR, or pass --lua-dir / --log-dir.
"""

from __future__ import annotations

import os
from pathlib import Path


def candidate_game_dirs() -> list[Path]:
    found: list[Path] = []
    env = os.environ.get("DUFLEET_GAME_DIR")
    if env:
        found.append(Path(env))
    program_data = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData"))
    for name in ("My Dual Universe", "Dual Universe"):
        found.append(program_data / name / "Game")
    try:
        for entry in sorted(program_data.iterdir()):
            game = entry / "Game"
            if "dual" in entry.name.lower() and game.is_dir() and game not in found:
                found.append(game)
    except OSError:
        pass
    return found


def find_lua_dir(explicit: str | Path | None = None) -> Path | None:
    if explicit:
        return Path(explicit)
    for game in candidate_game_dirs():
        lua = game / "data" / "lua"
        if lua.is_dir():
            return lua
    return None


def custom_dir(lua_dir: Path) -> Path:
    return lua_dir / "autoconf" / "custom"


def candidate_log_dirs(explicit: str | Path | None = None) -> list[Path]:
    if explicit:
        return [Path(explicit)]
    env = os.environ.get("DUFLEET_LOG_DIR")
    if env:
        return [Path(env)]
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        return []
    nq = Path(local) / "NQ"
    dirs: list[Path] = []
    try:
        for entry in sorted(nq.iterdir()):
            if entry.is_dir():
                log = entry / "log"
                dirs.append(log if log.is_dir() else entry)
    except OSError:
        pass
    return dirs


def newest_logs(dirs: list[Path], limit: int = 5) -> list[Path]:
    files: list[Path] = []
    for d in dirs:
        try:
            files.extend(p for p in d.glob("*.xml") if p.is_file())
        except OSError:
            continue
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files[:limit]
