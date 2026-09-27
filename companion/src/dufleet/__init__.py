"""mydu-fleet companion (see docs/plan.md, Phase 1 workstream 5)."""

import os
from pathlib import Path

__version__ = "0.1.0"

# The repository checkout the companion runs from: the Lua bus and its simulator live under lua/.
REPO = Path(os.environ.get("DUFLEET_REPO", Path(__file__).resolve().parents[3]))
