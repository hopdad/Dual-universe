import tomllib

import pytest
from conftest import ROOT

from dufleet import config

GOOD = """
[hub]
url = "https://abc.supabase.co/"
publishable_key = "sb_publishable_x"
email = "hauler-1@devices.example"

[bot]
id = "11111111-2222-3333-4444-555555555555"
"""


def write(tmp_path, text):
    path = tmp_path / "companion.toml"
    path.write_text(text, encoding="utf-8")
    return path


def test_a_minimal_file_gets_the_defaults(tmp_path):
    cfg = config.load(write(tmp_path, GOOD))
    assert cfg.hub.url == "https://abc.supabase.co"
    assert str(cfg.bot.id) == "11111111-2222-3333-4444-555555555555"
    assert (cfg.transport.kind, cfg.pump.lease_s, cfg.pump.idle_s, cfg.pump.lost_s, cfg.game.lua_dir) == (
        "sim", 60, 10.0, 30.0, None)


@pytest.mark.parametrize(("change", "where"), [
    (lambda t: t + "\n[pump]\nidle = 5\n", "pump.idle"),
    (lambda t: t.replace('"https://abc.supabase.co/"', '"abc.supabase.co"'), "hub.url"),
    (lambda t: t.replace('"11111111-2222-3333-4444-555555555555"', '"hauler-1"'), "bot.id"),
    (lambda t: t.split("[bot]")[0], "bot"),
    (lambda t: t + '\n[transport]\nkind = "optical"\n', "transport.kind"),
    (lambda t: t + "\n[pump]\nlease_s = 5\n", "pump.lease_s"),
])
def test_mistakes_are_reported_by_key(tmp_path, change, where):
    with pytest.raises(config.ConfigError, match=rf"companion\.toml: .*{where}"):
        config.load(write(tmp_path, change(GOOD)))


def test_unreadable_files_are_reported(tmp_path):
    with pytest.raises(config.ConfigError, match="cannot read"):
        config.load(tmp_path / "missing.toml")
    with pytest.raises(config.ConfigError, match="companion.toml"):
        config.load(write(tmp_path, "[hub\n"))


def test_the_password_comes_from_the_environment(monkeypatch):
    cfg = config.parse(tomllib.loads(GOOD))
    monkeypatch.delenv("DUFLEET_DEVICE_PASSWORD", raising=False)
    with pytest.raises(config.ConfigError, match="DUFLEET_DEVICE_PASSWORD"):
        cfg.hub.password()
    monkeypatch.setenv("DUFLEET_DEVICE_PASSWORD", "s3cret")
    assert cfg.hub.password() == "s3cret"


def test_the_example_file_is_valid():
    cfg = config.load(ROOT / "companion" / "companion.example.toml")
    assert cfg.transport.kind == "sim"
