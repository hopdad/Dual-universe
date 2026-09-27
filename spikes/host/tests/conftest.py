import shutil

import pytest

LUA = shutil.which("lua5.3") or shutil.which("lua5.4") or shutil.which("lua")
needs_lua = pytest.mark.skipif(LUA is None, reason="needs a Lua 5.3+ interpreter")
