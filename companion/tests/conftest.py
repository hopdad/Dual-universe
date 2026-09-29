import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = ROOT / "packages" / "protocol"


def _lua_bus_ready() -> bool:
    """What the real Lua bus in its fake ArchHUD (lua/tools/simulate.lua) needs: lua5.3 on PATH
    with dkjson, and lua/.deps from lua/tools/deps.sh."""
    lua = shutil.which("lua5.3")
    if not lua or not (ROOT / "lua" / ".deps" / "du-mocks").is_dir():
        return False
    return subprocess.run([lua, "-e", "require('dkjson')"], capture_output=True).returncode == 0


needs_lua_bus = pytest.mark.skipif(not _lua_bus_ready(), reason="needs lua5.3 with dkjson, and lua/tools/deps.sh")


def load_tool(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def vectors() -> dict:
    return json.loads((PROTOCOL / "vectors.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def schema() -> dict:
    return json.loads((PROTOCOL / "protocol.schema.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def pg_database() -> str:
    """A fresh hub database for the tests that run against the real SQL (opt-in)."""
    if not os.environ.get("DUFLEET_PG_TESTS"):
        pytest.skip("set DUFLEET_PG_TESTS=1 and the libpq variables to run against PostgreSQL")
    from pg_hub import prepare_database

    return prepare_database()
