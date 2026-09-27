"""Locations inside the probe kit and small helpers shared by the commands."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

HOST_DIR = Path(__file__).resolve().parents[2]  # spikes/host
KIT_DIR = HOST_DIR.parent  # spikes
# Mirrors <game>/data/lua/autoconf/custom, so installing is a straight copy.
LUA_SOURCE = KIT_DIR / "lua" / "autoconf" / "custom"
LUA_TESTS = KIT_DIR / "lua" / "tests"
DEFAULT_RESULTS = KIT_DIR / "results"

# The real bus, from the repository's lua/ folder (install --bus).
BUS_SOURCE = KIT_DIR.parent / "lua" / "autoconf" / "custom"

PROBE_FILES = (
    "archhud/userclass.lua",
    "dufleet/probe.lua",
    "dufleet/optical.lua",
    "dufleet/probe_config.lua",
)

IS_WINDOWS = sys.platform == "win32"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def save_json(results_dir: Path, name: str, data: Any) -> Path:
    results_dir.mkdir(parents=True, exist_ok=True)
    path = results_dir / name
    path.write_text(json.dumps(data, indent=2, default=str) + "\n", encoding="utf-8")
    return path


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def bus_files() -> list[str]:
    """The bus's files under autoconf/custom: the userclass.lua shim and every dufleet/*.lua module."""
    return ["archhud/userclass.lua", *sorted(f"dufleet/{p.name}" for p in (BUS_SOURCE / "dufleet").glob("*.lua"))]
