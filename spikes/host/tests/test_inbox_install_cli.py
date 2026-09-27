import io
import os
import subprocess
import zipfile
from argparse import Namespace

import pytest
from conftest import LUA, needs_lua

from dufleet_probe import inbox, inject, install, pins
from dufleet_probe.cli import main
from dufleet_probe.kit import LUA_TESTS, sha256_bytes


def test_inbox_write_is_atomic_and_valid_lua(tmp_path):
    path = tmp_path / "autoconf" / "custom" / "dufleet" / "inbox.lua"
    inbox.write_atomic(path, inbox.render(7, 1790000000.5))
    inbox.write_atomic(path, inbox.render(8, 1790000001.5))
    assert not path.with_name("inbox.lua.tmp").exists()
    if LUA:
        out = subprocess.run([LUA, "-e", f"local t = dofile([[{path}]]) print(t.seq, t.t, t.host)"],
                             capture_output=True, text=True, check=True).stdout.split()
        assert out[0] == "8" and float(out[1]) == pytest.approx(1790000001.5) and out[2] == "probe"


def _lua_tree(tmp_path):
    lua = tmp_path / "Game" / "data" / "lua"
    custom = lua / "autoconf" / "custom"
    (custom / "archhud").mkdir(parents=True)
    return lua, custom


def test_probe_install_and_uninstall_restores_players_userclass(tmp_path):
    lua, custom = _lua_tree(tmp_path)
    own = custom / "archhud" / "userclass.lua"
    own.write_text("-- my own tweaks\nuserBase = {}\n", encoding="utf-8")
    args = Namespace(lua_dir=str(lua), archhud=None, atlas=None, probe=True, uninstall_probe=False,
                     no_verify=False, apply=False, results=tmp_path / "results")
    install.run(args)  # dry run
    assert own.read_text(encoding="utf-8").startswith("-- my own")
    args.apply = True
    install.run(args)
    assert b"dufleet probe shim" in own.read_bytes()
    assert (custom / "dufleet" / "probe.lua").is_file()
    assert len(list((custom / "_dufleet_backup").glob("*/archhud/userclass.lua"))) == 1
    install.run(args)  # reinstalling the same files changes nothing
    assert len(list((custom / "_dufleet_backup").glob("*/archhud/userclass.lua"))) == 1
    (custom / "dufleet" / "inbox.lua").write_text("return {seq = 1}", encoding="utf-8")
    args.probe, args.uninstall_probe = False, True
    install.run(args)
    assert own.read_text(encoding="utf-8").startswith("-- my own")
    assert not (custom / "dufleet").exists()


def test_bus_install_replaces_the_probe_and_uninstalls_cleanly(tmp_path):
    lua, custom = _lua_tree(tmp_path)
    args = Namespace(lua_dir=str(lua), archhud=None, atlas=None, probe=True, bus=False, uninstall_probe=False,
                     no_verify=False, apply=True, results=tmp_path / "results")
    install.run(args)
    args.probe, args.bus = False, True
    install.run(args)
    shim = custom / "archhud" / "userclass.lua"
    assert b"dufleet bus shim" in shim.read_bytes()
    for name in ("bus.lua", "dispatcher.lua", "protocol_gen.lua", "archhud_adapter.lua", "runtime.lua",
                 "skills/goto.lua"):
        assert (custom / "dufleet" / name).is_file(), name
    args.bus, args.uninstall_probe = False, True
    install.run(args)
    assert not shim.exists() and not (custom / "dufleet").exists()


def test_probe_and_bus_together_are_refused(tmp_path):
    lua, _ = _lua_tree(tmp_path)
    args = Namespace(lua_dir=str(lua), archhud=None, atlas=None, probe=True, bus=True, uninstall_probe=False,
                     no_verify=False, apply=False, results=tmp_path / "results")
    with pytest.raises(SystemExit):
        install.run(args)


def test_uninstall_keeps_a_userclass_that_is_not_ours(tmp_path):
    lua, custom = _lua_tree(tmp_path)
    own = custom / "archhud" / "userclass.lua"
    own.write_text("-- mine\n", encoding="utf-8")
    report = install.uninstall_probe(custom, dry_run=False)
    assert own.exists() and report["kept"]


def test_archhud_sources_are_checked_against_pins(tmp_path, monkeypatch):
    src = tmp_path / "archhud-src"
    for repo in pins.ARCHHUD_FILES:
        (src / repo).parent.mkdir(parents=True, exist_ok=True)
        (src / repo).write_bytes(b"x")
    with pytest.raises(SystemExit):
        install.archhud_files(str(src), verify=True)
    assert len(install.archhud_files(str(src), verify=False)) == len(pins.ARCHHUD_FILES)
    fake = {repo: (rel, sha256_bytes(b"x")) for repo, (rel, _) in pins.ARCHHUD_FILES.items()}
    monkeypatch.setattr(pins, "ARCHHUD_FILES", fake)
    writes = install.archhud_files(str(src), verify=True)
    assert {w.rel for w in writes} == {rel for rel, _ in fake.values()}


def test_codeload_style_zip_is_understood(tmp_path):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for repo in pins.ARCHHUD_FILES:
            z.writestr(f"ArchHUD-{pins.ARCHHUD_COMMIT}/{repo}", repo.encode())
        z.writestr(f"ArchHUD-{pins.ARCHHUD_COMMIT}/README.md", b"readme")
    files = install._from_zip(buf.getvalue())
    assert set(files) == set(pins.ARCHHUD_FILES)
    assert files["ArchHUD.conf"] == b"ArchHUD.conf"


def test_sweep_lines_have_exact_lengths():
    for n, line in zip(inject.SWEEP, inject.sweep_lines(), strict=True):
        assert len(line) == n and line.startswith(f"/b echo L{n} ")


def test_cli_selftest_and_dry_run(tmp_path, capsys):
    assert main(["--results", str(tmp_path), "optical", "selftest"]) == 0
    assert main(["--results", str(tmp_path), "inject", "--dry-run", "--count", "2"]) == 0
    out = capsys.readouterr().out
    assert "selftest passed" in out and "/b ping 2" in out


@needs_lua
def test_lua_probe_suite(tmp_path):
    result = subprocess.run([LUA, str(LUA_TESTS / "test_probe.lua")], capture_output=True, text=True,
                            env={**os.environ, "DUFLEET_TMP": str(tmp_path)})
    assert result.returncode == 0, result.stdout + result.stderr
