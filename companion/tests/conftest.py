import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = ROOT / "packages" / "protocol"


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
