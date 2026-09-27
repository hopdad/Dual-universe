"""The game's Lua folder: finding it, installing ArchHUD, the atlas and the bus, and checking them.

Everything the companion writes lives under <game>/data/lua/autoconf/custom (CLAUDE.md):
ArchHUD's own files and atlas.lua (both pinned in pins.py), archhud/userclass.lua (the bus
shim) and dufleet/. The bus comes from the repository's lua/ folder.

- `install` is a dry run unless `apply` is set. Files that already match are left alone.
  A file that differs is copied to autoconf/custom/_dufleet_backup/<time>/ before it is
  replaced, and each write goes to a temporary file first, then is renamed into place.
  Installing the bus also removes (after the same backup) files in dufleet/ that the bus
  does not have, such as the probe kit's. It keeps dufleet/inbox.lua, which the companion
  writes itself (Transport F).
- `doctor` checks every part by SHA-256 against the pins and the repository.

Where the myDU client lives is spike S8's question. The defaults follow the ClientModManager
README (C:\\ProgramData\\My Dual Universe) and the official client (C:\\ProgramData\\Dual
Universe); DUFLEET_GAME_DIR or --lua-dir overrides them.
"""

from __future__ import annotations

import hashlib
import io
import os
import re
import shutil
import time
import urllib.error
import urllib.request
import zipfile
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from dufleet import REPO, pins

BUS_SOURCE = REPO / "lua" / "autoconf" / "custom"
SHIM = "archhud/userclass.lua"
BUS_MARKER = b"dufleet bus shim"
PROBE_MARKER = b"dufleet probe shim"
KEEP = frozenset({"dufleet/inbox.lua"})
BACKUP_DIR = "_dufleet_backup"


class InstallError(Exception):
    """A source that cannot be read, or an upstream file that does not match its pin."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# Paths


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
    """The game's data/lua folder: `explicit` if given, else the first candidate that exists."""
    if explicit:
        return Path(explicit)
    for game in candidate_game_dirs():
        lua = game / "data" / "lua"
        if lua.is_dir():
            return lua
    return None


def custom_dir(lua_dir: Path) -> Path:
    return lua_dir / "autoconf" / "custom"


# Sources


def bus_files(source: Path = BUS_SOURCE) -> dict[str, bytes]:
    """The bus as the repository has it: path under autoconf/custom -> content."""
    files = {SHIM: (source / SHIM).read_bytes()}
    for path in sorted((source / "dufleet").rglob("*.lua")):
        files[path.relative_to(source).as_posix()] = path.read_bytes()
    return files


def bus_version(files: dict[str, bytes]) -> str | None:
    match = re.search(rb'VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"', files.get("dufleet/bus.lua", b""))
    return match.group(1).decode() if match else None


def _download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "dufleet"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except (urllib.error.URLError, TimeoutError) as exc:
        raise InstallError(f"could not download {url}: {exc}. Download it by hand and pass the file, "
                           "folder or zip instead of 'fetch'") from None


def _check_pin(name: str, data: bytes, sha: str, verify: bool, warn: Callable[[str], None]) -> None:
    actual = sha256(data)
    if actual != sha:
        message = f"{name}: SHA-256 {actual[:12]}... is not the pinned {sha[:12]}..."
        if verify:
            raise InstallError(message + " (--no-verify installs it anyway)")
        warn(message)


def _from_zip(blob: bytes) -> dict[str, bytes]:
    """The pinned files in a zip of the ArchHUD repository, with or without its top folder."""
    out: dict[str, bytes] = {}
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        for name in z.namelist():
            repo_path = name if name in pins.ARCHHUD_FILES else name.split("/", 1)[-1]
            if repo_path in pins.ARCHHUD_FILES:
                out[repo_path] = z.read(name)
    return out


def archhud_files(source: str, verify: bool = True, warn: Callable[[str], None] = print) -> dict[str, bytes]:
    """ArchHUD's pinned files from 'fetch' (GitHub at the pinned commit), a checkout folder or
    a zip of the repository: path under autoconf/custom -> content."""
    if source == "fetch":
        found = {repo: _download(pins.ARCHHUD_RAW_URL + repo) for repo in pins.ARCHHUD_FILES}
    else:
        path = Path(source)
        if path.is_file() and path.suffix.lower() == ".zip":
            found = _from_zip(path.read_bytes())
        elif path.is_dir():
            found = {repo: (path / repo).read_bytes() for repo in pins.ARCHHUD_FILES if (path / repo).is_file()}
        else:
            raise InstallError(f"{source} is not 'fetch', a folder or a .zip")
    out = {}
    for repo, (rel, sha) in pins.ARCHHUD_FILES.items():
        if repo not in found:
            raise InstallError(f"the ArchHUD source has no {repo}")
        _check_pin(repo, found[repo], sha, verify, warn)
        out[rel] = found[repo]
    return out


def atlas_file(source: str, verify: bool = True, warn: Callable[[str], None] = print) -> dict[str, bytes]:
    """The Third Verse's atlas.lua from 'fetch' or a file."""
    rel, sha = pins.ATLAS_FILE
    try:
        data = _download(pins.ATLAS_URL) if source == "fetch" else Path(source).read_bytes()
    except OSError as exc:
        raise InstallError(f"cannot read {source}: {exc}") from None
    _check_pin("atlas.lua", data, sha, verify, warn)
    return {rel: data}


# Install


@dataclass
class InstallReport:
    written: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)
    backed_up: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)
    backup_dir: Path | None = None


def _backup(path: Path, custom: Path, root: Path) -> None:
    dest = root / path.relative_to(custom)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)


def install(custom: Path, files: dict[str, bytes], *, apply: bool, stamp: str | None = None) -> InstallReport:
    """Writes `files` (path under autoconf/custom -> content) into `custom`."""
    report = InstallReport(backup_dir=custom / BACKUP_DIR / (stamp or time.strftime("%Y%m%d-%H%M%S")))
    for rel, data in files.items():
        dest = custom / rel
        if dest.is_file():
            if sha256(dest.read_bytes()) == sha256(data):
                report.unchanged.append(rel)
                continue
            report.backed_up.append(rel)
            if apply:
                _backup(dest, custom, report.backup_dir)
        report.written.append(rel)
        if apply:
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_name(dest.name + ".dufleet-tmp")
            tmp.write_bytes(data)
            os.replace(tmp, dest)
    folder = custom / "dufleet"
    if SHIM in files and folder.is_dir():  # the bus owns dufleet/: drop what it does not have
        for path in sorted(p for p in folder.rglob("*") if p.is_file()):
            rel = path.relative_to(custom).as_posix()
            if rel not in files and rel not in KEEP:
                report.removed.append(rel)
                if apply:
                    _backup(path, custom, report.backup_dir)
                    path.unlink()
    if not report.backed_up and not report.removed:
        report.backup_dir = None
    return report


# Doctor


@dataclass
class Check:
    name: str
    status: str  # "ok", "warn" or "fail"
    detail: str


def _listing(names: list[str], limit: int = 3) -> str:
    more = f" and {len(names) - limit} more" if len(names) > limit else ""
    return ", ".join(names[:limit]) + more


def _mismatches(custom: Path, expected: dict[str, str]) -> tuple[list[str], list[str]]:
    """Missing and differing files among expected (path -> SHA-256)."""
    missing, differ = [], []
    for rel, sha in expected.items():
        path = custom / rel
        if not path.is_file():
            missing.append(rel)
        elif sha256(path.read_bytes()) != sha:
            differ.append(rel)
    return missing, differ


def check_archhud(custom: Path) -> Check:
    missing, differ = _mismatches(custom, dict(pins.ARCHHUD_FILES.values()))
    commit = pins.ARCHHUD_COMMIT[:7]
    if len(missing) == len(pins.ARCHHUD_FILES):
        return Check("archhud", "fail", "not installed: dufleet install --archhud fetch --apply")
    if missing:
        return Check("archhud", "fail", f"missing {_listing(missing)}")
    if differ:
        return Check("archhud", "fail", f"{_listing(differ)} differ from {pins.ARCHHUD_REPO} at {commit}")
    return Check("archhud", "ok", f"ArchHUD {pins.ARCHHUD_VERSION} at {commit}, {len(pins.ARCHHUD_FILES)} files")


def check_atlas(custom: Path) -> Check:
    rel, sha = pins.ATLAS_FILE
    path, commit = custom / rel, pins.ATLAS_COMMIT[:7]
    if not path.is_file():
        return Check("atlas", "warn", "no atlas.lua: ArchHUD falls back to NQ's atlas, which may not match the "
                                      "server (dufleet install --atlas fetch --apply)")
    if sha256(path.read_bytes()) != sha:
        return Check("atlas", "warn", f"atlas.lua differs from {pins.ATLAS_REPO} at {commit}; fine if the server "
                                      "changed its atlas")
    return Check("atlas", "ok", f"{pins.ATLAS_REPO} at {commit}")


def check_bus(custom: Path, files: dict[str, bytes]) -> list[Check]:
    """The shim and the modules against the repository's copy."""
    shim = custom / SHIM
    data = shim.read_bytes() if shim.is_file() else b""
    if BUS_MARKER in data:
        shim_check = Check("userclass", "ok", "the bus shim")
    elif PROBE_MARKER in data:
        shim_check = Check("userclass", "fail", "the probe kit's shim, not the bus's: dufleet install --apply")
    elif data:
        shim_check = Check("userclass", "fail", "someone else's userclass.lua: dufleet install --apply backs it "
                                                "up and replaces it")
    else:
        shim_check = Check("userclass", "fail", "missing: dufleet install --apply")
    modules = {rel: sha256(content) for rel, content in files.items() if rel != SHIM}
    missing, differ = _mismatches(custom, modules)
    folder = custom / "dufleet"
    extra = []
    if folder.is_dir():
        for path in sorted(p for p in folder.rglob("*") if p.is_file()):
            rel = path.relative_to(custom).as_posix()
            if rel not in modules and rel not in KEEP:
                extra.append(rel)
    version = bus_version(files)
    if len(missing) == len(modules):
        bus = Check("bus", "fail", "not installed: dufleet install --apply")
    elif missing or differ:
        stale = _listing(missing + differ)
        bus = Check("bus", "fail", f"{stale} missing or older than lua/ in the repository: dufleet install --apply")
    elif extra:
        bus = Check("bus", "warn", f"bus {version} installed, plus files it does not use: {_listing(extra)}")
    else:
        bus = Check("bus", "ok", f"bus {version}, {len(modules)} modules")
    return [shim_check, bus]


def doctor(lua_dir: Path | None, files: dict[str, bytes] | None = None) -> list[Check]:
    """Every check, in order. A missing game folder is the only check then."""
    if lua_dir is None or not custom_dir(lua_dir).is_dir():
        where = f"{custom_dir(lua_dir)} does not exist" if lua_dir else "not found"
        return [Check("game", "fail", f"game Lua folder {where}; pass --lua-dir or set DUFLEET_GAME_DIR")]
    custom = custom_dir(lua_dir)
    return [Check("game", "ok", str(lua_dir)), check_archhud(custom), check_atlas(custom),
            *check_bus(custom, bus_files() if files is None else files)]
