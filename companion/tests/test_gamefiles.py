"""dufleet install and doctor against a scratch game folder, with fake upstream files."""

import importlib.util
import json
import zipfile

import pytest
from conftest import ROOT

from dufleet import gamefiles, pins
from dufleet.cli import main
from dufleet.gamefiles import sha256


@pytest.fixture
def game(tmp_path):
    lua = tmp_path / "Game" / "data" / "lua"
    (lua / "autoconf" / "custom").mkdir(parents=True)
    return lua


@pytest.fixture
def upstream(tmp_path, monkeypatch):
    """A fake ArchHUD checkout and atlas.lua, with the pins pointed at them."""
    checkout = tmp_path / "ArchHUD"
    fake_pins = {}
    for repo_path, (rel, _) in pins.ARCHHUD_FILES.items():
        data = f"-- {repo_path}\n".encode()
        (checkout / repo_path).parent.mkdir(parents=True, exist_ok=True)
        (checkout / repo_path).write_bytes(data)
        fake_pins[repo_path] = (rel, sha256(data))
    monkeypatch.setattr(pins, "ARCHHUD_FILES", fake_pins)
    atlas = tmp_path / "atlas.lua"
    atlas.write_bytes(b"return {}\n")
    monkeypatch.setattr(pins, "ATLAS_FILE", ("atlas.lua", sha256(atlas.read_bytes())))
    return checkout, atlas


def statuses(checks):
    return {c.name: c.status for c in checks}


def test_the_pins_agree_with_the_probe_kit():
    path = ROOT / "spikes" / "host" / "src" / "dufleet_probe" / "pins.py"
    spec = importlib.util.spec_from_file_location("probe_pins", path)
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    for name in ("ARCHHUD_REPO", "ARCHHUD_COMMIT", "ARCHHUD_FILES", "ATLAS_REPO", "ATLAS_COMMIT", "ATLAS_FILE"):
        assert getattr(pins, name) == getattr(probe, name), name


def test_the_lua_contract_tests_fetch_the_pinned_commits():
    deps = (ROOT / "lua" / "tools" / "deps.sh").read_text(encoding="utf-8")
    assert f"https://github.com/{pins.ARCHHUD_REPO} {pins.ARCHHUD_COMMIT}" in deps
    assert f"https://github.com/{pins.ATLAS_REPO} {pins.ATLAS_COMMIT}" in deps


def test_the_game_folder_is_found_under_programdata(tmp_path, monkeypatch):
    lua = tmp_path / "My Dual Universe" / "Game" / "data" / "lua"
    lua.mkdir(parents=True)
    monkeypatch.delenv("DUFLEET_GAME_DIR", raising=False)
    monkeypatch.setenv("PROGRAMDATA", str(tmp_path))
    assert gamefiles.find_lua_dir() == lua
    monkeypatch.setenv("DUFLEET_GAME_DIR", str(tmp_path / "elsewhere" / "Game"))
    (tmp_path / "elsewhere" / "Game" / "data" / "lua").mkdir(parents=True)
    assert gamefiles.find_lua_dir() == tmp_path / "elsewhere" / "Game" / "data" / "lua"
    assert gamefiles.find_lua_dir("X:/given") == gamefiles.Path("X:/given")


def test_the_bus_is_the_shim_and_every_module_under_dufleet():
    files = gamefiles.bus_files()
    for rel in ("archhud/userclass.lua", "dufleet/bus.lua", "dufleet/runtime.lua", "dufleet/skills/goto.lua",
                "dufleet/protocol_gen.lua"):
        assert rel in files, rel
    assert gamefiles.BUS_MARKER in files["archhud/userclass.lua"]
    assert gamefiles.bus_version(files).count(".") == 2


def test_a_dry_run_writes_nothing(game):
    custom = gamefiles.custom_dir(game)
    report = gamefiles.install(custom, gamefiles.bus_files(), apply=False)
    assert "dufleet/bus.lua" in report.written
    assert not (custom / "dufleet").exists() and not (custom / "archhud").exists()


def test_install_writes_the_bus_once(game):
    custom = gamefiles.custom_dir(game)
    files = gamefiles.bus_files()
    report = gamefiles.install(custom, files, apply=True)
    assert sorted(report.written) == sorted(files)
    assert report.backup_dir is None
    assert (custom / "dufleet" / "skills" / "goto.lua").read_bytes() == files["dufleet/skills/goto.lua"]
    again = gamefiles.install(custom, files, apply=True)
    assert again.written == [] and sorted(again.unchanged) == sorted(files)
    assert not list(custom.rglob("*.dufleet-tmp"))


def test_install_backs_up_what_it_replaces_or_removes(game):
    custom = gamefiles.custom_dir(game)
    (custom / "archhud").mkdir()
    (custom / "archhud" / "userclass.lua").write_text("-- my own userclass\n")
    (custom / "dufleet").mkdir()
    (custom / "dufleet" / "probe.lua").write_text("-- the probe kit\n")
    (custom / "dufleet" / "inbox.lua").write_text("return { v = 1, n = 3, lines = {} }\n")
    report = gamefiles.install(custom, gamefiles.bus_files(), apply=True, stamp="t1")
    assert report.backed_up == ["archhud/userclass.lua"]
    assert report.removed == ["dufleet/probe.lua"]
    backup = custom / "_dufleet_backup" / "t1"
    assert (backup / "archhud" / "userclass.lua").read_text() == "-- my own userclass\n"
    assert (backup / "dufleet" / "probe.lua").is_file()
    assert not (custom / "dufleet" / "probe.lua").exists()
    assert (custom / "dufleet" / "inbox.lua").is_file()  # the companion's own inbox stays


def test_archhud_comes_from_a_checkout_or_a_zip(upstream, tmp_path):
    checkout, _ = upstream
    from_folder = gamefiles.archhud_files(str(checkout))
    assert set(from_folder) == {rel for rel, _ in pins.ARCHHUD_FILES.values()}
    archive = tmp_path / "ArchHUD.zip"
    with zipfile.ZipFile(archive, "w") as z:
        for repo_path in pins.ARCHHUD_FILES:
            z.write(checkout / repo_path, f"ArchHUD-{pins.ARCHHUD_COMMIT}/{repo_path}")
    assert gamefiles.archhud_files(str(archive)) == from_folder


def test_upstream_files_must_match_their_pins(upstream):
    checkout, atlas = upstream
    (checkout / "src" / "requires" / "apclass.lua").write_bytes(b"-- edited\n")
    with pytest.raises(gamefiles.InstallError, match="apclass.lua"):
        gamefiles.archhud_files(str(checkout))
    warnings = []
    gamefiles.archhud_files(str(checkout), verify=False, warn=warnings.append)
    assert len(warnings) == 1 and "apclass.lua" in warnings[0]
    atlas.write_bytes(b"return { edited = true }\n")
    with pytest.raises(gamefiles.InstallError, match="atlas.lua"):
        gamefiles.atlas_file(str(atlas))
    with pytest.raises(gamefiles.InstallError, match="neither"):
        gamefiles.archhud_files("neither")


def test_doctor_without_a_game_folder(tmp_path):
    checks = gamefiles.doctor(None)
    assert [(c.name, c.status) for c in checks] == [("game", "fail")]
    assert "not found" in checks[0].detail
    assert "does not exist" in gamefiles.doctor(tmp_path / "nowhere")[0].detail


def test_doctor_after_a_full_install(game, upstream):
    checkout, atlas = upstream
    custom = gamefiles.custom_dir(game)
    files = {**gamefiles.archhud_files(str(checkout)), **gamefiles.atlas_file(str(atlas)), **gamefiles.bus_files()}
    gamefiles.install(custom, files, apply=True)
    checks = gamefiles.doctor(game)
    assert statuses(checks) == {"game": "ok", "archhud": "ok", "atlas": "ok", "userclass": "ok", "bus": "ok"}


def test_doctor_names_what_is_wrong(game, upstream):
    checkout, _ = upstream
    custom = gamefiles.custom_dir(game)
    assert statuses(gamefiles.doctor(game)) == {"game": "ok", "archhud": "fail", "atlas": "warn",
                                                "userclass": "fail", "bus": "fail"}
    gamefiles.install(custom, {**gamefiles.archhud_files(str(checkout)), **gamefiles.bus_files()}, apply=True)
    (custom / "archhud" / "hudclass.lua").write_bytes(b"-- edited\n")
    (custom / "dufleet" / "runtime.lua").write_bytes(b"-- older\n")
    (custom / "dufleet" / "notes.lua").write_bytes(b"-- stray\n")
    (custom / "atlas.lua").write_bytes(b"return { newer = true }\n")
    checks = {c.name: c for c in gamefiles.doctor(game)}
    assert checks["archhud"].status == "fail" and "archhud/hudclass.lua" in checks["archhud"].detail
    assert checks["atlas"].status == "warn" and "differs" in checks["atlas"].detail
    assert checks["bus"].status == "fail" and "dufleet/runtime.lua" in checks["bus"].detail
    gamefiles.install(custom, gamefiles.bus_files(), apply=True)
    (custom / "dufleet" / "notes.lua").write_bytes(b"-- stray\n")
    checks = {c.name: c for c in gamefiles.doctor(game)}
    assert checks["bus"].status == "warn" and "dufleet/notes.lua" in checks["bus"].detail


def test_doctor_tells_the_probe_from_the_bus(game):
    custom = gamefiles.custom_dir(game)
    gamefiles.install(custom, gamefiles.bus_files(), apply=True)
    (custom / "archhud" / "userclass.lua").write_bytes(b"-- dufleet probe shim\n")
    checks = {c.name: c for c in gamefiles.doctor(game)}
    assert checks["userclass"].status == "fail" and "probe" in checks["userclass"].detail


def test_the_install_and_doctor_commands(game, upstream, capsys):
    checkout, atlas = upstream
    lua = ["--lua-dir", str(game)]
    assert main(["install", *lua, "--archhud", str(checkout), "--atlas", str(atlas)]) == 0
    out = capsys.readouterr().out
    assert "written    dufleet/bus.lua" in out and "Dry run" in out
    assert main(["doctor", *lua]) == 1
    capsys.readouterr()
    assert main(["install", *lua, "--archhud", str(checkout), "--atlas", str(atlas), "--apply"]) == 0
    assert "ok    bus" in capsys.readouterr().out  # install ends with the doctor's checks
    assert main(["doctor", *lua, "--json"]) == 0
    assert {c["status"] for c in json.loads(capsys.readouterr().out)} == {"ok"}


def test_install_refuses_a_missing_folder_or_a_bad_source(tmp_path, capsys):
    assert main(["install", "--lua-dir", str(tmp_path / "nowhere")]) == 2
    assert "not found" in capsys.readouterr().err
    (tmp_path / "lua" / "autoconf" / "custom").mkdir(parents=True)
    assert main(["install", "--lua-dir", str(tmp_path / "lua"), "--archhud", str(tmp_path / "missing.zip")]) == 2
    assert "not 'fetch', a folder or a .zip" in capsys.readouterr().err


def test_a_zip_without_the_files_is_refused(tmp_path, upstream):
    archive = tmp_path / "empty.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("README.md", "nothing here")
    with pytest.raises(gamefiles.InstallError, match="has no"):
        gamefiles.archhud_files(str(archive))
