"""Puts ArchHUD, The Third Verse's atlas and the probe into the game's Lua folder.

Dry run by default: prints what it would do. Add --apply to write. Upstream files are
checked against the SHA-256 pins in pins.py. An existing file that differs is copied
to autoconf/custom/_dufleet_backup/<time>/ before it is replaced, and
--uninstall-probe puts back a userclass.lua the install had replaced.
"""

from __future__ import annotations

import io
import os
import shutil
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

from dufleet_probe import pins
from dufleet_probe.gamepaths import custom_dir, find_lua_dir
from dufleet_probe.kit import LUA_SOURCE, PROBE_FILES, save_json, sha256_bytes, sha256_file

BACKUP_DIR = "_dufleet_backup"
SHIM = "archhud/userclass.lua"
SHIM_MARKER = b"dufleet probe shim"


@dataclass
class Write:
    rel: str  # path under autoconf/custom
    data: bytes
    source: str


def _download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "dufleet-probe"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except (urllib.error.URLError, TimeoutError) as exc:
        raise SystemExit(f"Could not download {url}: {exc}\n"
                         "Download it by hand and pass the file, folder or zip instead of 'fetch'.") from None


def _check(name: str, data: bytes, sha: str, verify: bool) -> None:
    actual = sha256_bytes(data)
    if actual != sha:
        message = f"{name}: SHA-256 {actual[:12]}... does not match the pinned {sha[:12]}..."
        if verify:
            raise SystemExit(message + " (--no-verify installs it anyway)")
        print("warning: " + message)


def _from_zip(blob: bytes) -> dict[str, bytes]:
    """Pinned files from a zip, with or without the "<repo>-<commit>/" top folder."""
    out: dict[str, bytes] = {}
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        for name in z.namelist():
            rel = name if name in pins.ARCHHUD_FILES else name.split("/", 1)[-1]
            if rel in pins.ARCHHUD_FILES:
                out[rel] = z.read(name)
    return out


def archhud_files(source: str, verify: bool) -> list[Write]:
    if source == "fetch":
        files = {repo: _download(pins.ARCHHUD_RAW_URL + repo) for repo in pins.ARCHHUD_FILES}
        origin = pins.ARCHHUD_RAW_URL
    else:
        path = Path(source)
        if path.is_file() and path.suffix.lower() == ".zip":
            files = _from_zip(path.read_bytes())
        elif path.is_dir():
            files = {repo: (path / repo).read_bytes() for repo in pins.ARCHHUD_FILES if (path / repo).is_file()}
        else:
            raise SystemExit(f"--archhud: {source} is not 'fetch', a folder or a .zip")
        origin = str(path)
    writes = []
    for repo, (rel, sha) in pins.ARCHHUD_FILES.items():
        if repo not in files:
            raise SystemExit(f"The ArchHUD source has no {repo}")
        _check(repo, files[repo], sha, verify)
        writes.append(Write(rel, files[repo], origin))
    return writes


def atlas_file(source: str, verify: bool) -> Write:
    rel, sha = pins.ATLAS_FILE
    data = _download(pins.ATLAS_URL) if source == "fetch" else Path(source).read_bytes()
    _check("atlas.lua", data, sha, verify)
    return Write(rel, data, pins.ATLAS_URL if source == "fetch" else source)


def probe_files() -> list[Write]:
    return [Write(rel, (LUA_SOURCE / rel).read_bytes(), "probe kit") for rel in PROBE_FILES]


def apply_writes(custom: Path, writes: list[Write], stamp: str, dry_run: bool) -> dict:
    report: dict[str, list[str]] = {"written": [], "unchanged": [], "backed_up": []}
    backup_root = custom / BACKUP_DIR / stamp
    for w in writes:
        dest = custom / w.rel
        if dest.is_file():
            if sha256_file(dest) == sha256_bytes(w.data):
                report["unchanged"].append(w.rel)
                continue
            report["backed_up"].append(w.rel)
            if not dry_run:
                backup = backup_root / w.rel
                backup.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dest, backup)
        report["written"].append(w.rel)
        if not dry_run:
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_name(dest.name + ".dufleet-tmp")
            tmp.write_bytes(w.data)
            os.replace(tmp, dest)
    return report


def uninstall_probe(custom: Path, dry_run: bool) -> dict:
    report: dict[str, list[str]] = {"removed": [], "restored": [], "kept": []}
    shim = custom / SHIM
    if shim.is_file():
        if SHIM_MARKER in shim.read_bytes():
            report["removed"].append(SHIM)
            if not dry_run:
                shim.unlink()
            backups = sorted((custom / BACKUP_DIR).glob(f"*/{SHIM}")) if (custom / BACKUP_DIR).is_dir() else []
            previous = [b for b in backups if SHIM_MARKER not in b.read_bytes()]
            if previous:  # the player's own userclass.lua, replaced by an earlier install
                report["restored"].append(str(previous[-1]))
                if not dry_run:
                    shutil.copy2(previous[-1], shim)
        else:
            report["kept"].append(SHIM + " (not the probe's)")
    folder = custom / "dufleet"
    if folder.is_dir():
        for path in sorted(folder.iterdir()):
            if path.is_file():
                report["removed"].append(f"dufleet/{path.name}")
                if not dry_run:
                    path.unlink()
        if not dry_run and not any(folder.iterdir()):
            folder.rmdir()
    return report


def run(args) -> int:
    lua = find_lua_dir(args.lua_dir)
    if lua is None:
        raise SystemExit("Game Lua folder not found; pass --lua-dir")
    custom = custom_dir(lua)
    if not custom.is_dir():
        raise SystemExit(f"{custom} does not exist; is --lua-dir right?")
    dry_run = not args.apply
    result: dict = {"lua_dir": str(lua), "dry_run": dry_run}
    if args.uninstall_probe:
        result["uninstall"] = uninstall_probe(custom, dry_run)
    else:
        writes: list[Write] = []
        if args.archhud:
            writes += archhud_files(args.archhud, not args.no_verify)
        if args.atlas:
            writes.append(atlas_file(args.atlas, not args.no_verify))
        if args.probe:
            writes += probe_files()
        if not writes:
            raise SystemExit("Nothing to do: pass --archhud, --atlas, --probe or --uninstall-probe")
        result["install"] = apply_writes(custom, writes, time.strftime("%Y%m%d-%H%M%S"), dry_run)
    for section in ("install", "uninstall"):
        for key, items in result.get(section, {}).items():
            for item in items:
                print(f"  {key:10} {item}")
    save_json(args.results, "install.json", result)
    if dry_run:
        print("Dry run: nothing was written. Add --apply to do it.")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("install", help="put ArchHUD, the atlas and the probe into the game's Lua folder")
    p.add_argument("--lua-dir", help="the game's data\\lua folder (default: detected)")
    p.add_argument("--archhud", metavar="fetch|FOLDER|ZIP", help="install ArchHUD 2.105 (pinned)")
    p.add_argument("--atlas", metavar="fetch|FILE", help="install The Third Verse's atlas.lua (pinned)")
    p.add_argument("--probe", action="store_true", help="install the probe (userclass.lua shim and dufleet/)")
    p.add_argument("--uninstall-probe", action="store_true", help="remove the probe, restore a replaced userclass.lua")
    p.add_argument("--no-verify", action="store_true", help="accept upstream files that do not match the pins")
    p.add_argument("--apply", action="store_true", help="actually write (default: dry run)")
    p.set_defaults(func=run)
