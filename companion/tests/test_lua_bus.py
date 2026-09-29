"""The real Lua bus, run in its fake ArchHUD, read back by the Python deframer.

Skipped unless lua5.3 (with dkjson) and lua/.deps (lua/tools/deps.sh) are present.
"""

import shutil
import subprocess

import pytest
from conftest import ROOT, needs_lua_bus
from jsonschema import Draft202012Validator

from dufleet.protocol import Deframer, build_command

LUA = shutil.which("lua5.3")
SIMULATOR = ROOT / "lua" / "tools" / "simulate.lua"

pytestmark = needs_lua_bus


def run_bus(script: list[str]) -> list[str]:
    result = subprocess.run(
        [LUA, str(SIMULATOR)], input="\n".join(script) + "\n", capture_output=True, text=True, check=True, timeout=60
    )
    return result.stdout.splitlines()


def deframe(lines: list[str]):
    d = Deframer(clock=lambda: 0.0)
    messages = [m for m in map(d.feed, lines) if m is not None]
    assert not d.dropped, d.dropped
    return messages


@pytest.fixture(scope="module")
def session():
    script = [
        build_command(1, 1, "ping"),
        "tick 2",
        build_command(1, 2, "setid", "hauler-1"),
        "tick 2",
        build_command(1, 3, "status"),
        "tick 2",
        build_command(1, 4, "db", "set", "dub.note", "a|b"),
        "tick 2",
        build_command(1, 5, "db", "get", "dub.note"),
        "tick 2",
        build_command(1, 5, "db", "get", "dub.note"),  # a retry: answered from the stored reply
        "tick 2",
        "/b 1.6 ping #0000",  # damaged in transit
        "tick 2",
        build_command(1, 6, "run", "goto", "j_7a1", "pos=0,2,35.3951,104.1187,285.5413"),
        "tick 2",
        "restart",
        build_command(1, 6, "run", "goto", "j_7a1", "pos=0,2,35.3951,104.1187,285.5413"),
        "tick 2",
        build_command(1, 4, "ping"),  # older than the watermark
        "tick 2",
        build_command(2, 1, "ping"),  # the hub's new epoch
        "tick 2",
    ]
    return deframe(run_bus(script))


def replies(messages):
    return [(m.kind, m.body) for m in messages if m.kind in ("A", "N")]


def test_every_body_matches_the_schema(session, schema):
    for m in session:
        name = schema["x-kind-bodies"][m.kind]
        validator = Draft202012Validator({"$defs": schema["$defs"], "$ref": f"#/$defs/{name}"})
        errors = list(validator.iter_errors(m.body))
        assert not errors, (m, errors)
    assert {m.kind for m in session} >= {"H", "T", "A", "N"}


def test_each_command_gets_the_right_reply(session):
    assert replies(session) == [
        ("A", {"ref": 1, "e": 1}),
        ("A", {"ref": 2, "e": 1}),
        ("A", {"ref": 3, "e": 1}),
        ("A", {"ref": 4, "e": 1}),
        ("A", {"ref": 5, "e": 1, "data": {"k": "dub.note", "v": "a|b"}}),
        ("A", {"ref": 5, "e": 1, "data": {"k": "dub.note", "v": "a|b"}, "dup": True}),
        ("N", {"ref": 6, "e": 1, "err": "E_CRC", "msg": "CRC mismatch"}),
        ("A", {"ref": 6, "e": 1, "job": "j_7a1"}),
        ("A", {"ref": 6, "e": 1, "job": "j_7a1", "dup": True}),
        ("N", {"ref": 4, "e": 1, "err": "E_STATE", "msg": "superseded by cseq 6"}),
        ("A", {"ref": 1, "e": 2}),
    ]


def test_frames_carry_the_new_id_and_restart_resets_seq(session):
    hellos = [m for m in session if m.kind == "H"]
    assert [h.body["id"] for h in hellos] == ["", "hauler-1", "hauler-1"]
    assert hellos[0].bot == "c4242" and hellos[1].bot == "hauler-1"
    assert hellos[2].body["epoch"] == 1 and hellos[2].body["cseq"] == 6
    assert hellos[0].body["boot"] != hellos[2].body["boot"]
    # seq counts from 1 at each start; the retry's reply outranks the new hello
    seqs = [m.seq for m in session]
    restarts = [i for i in range(1, len(seqs)) if seqs[i] < seqs[i - 1]]
    assert len(restarts) == 1 and seqs[restarts[0]] == 1
    assert session[restarts[0]].kind == "A" and session[restarts[0]].body.get("dup") is True


def test_a_job_cut_off_by_a_restart_is_reported(session):
    moves = [(m.body["from"], m.body["to"]) for m in session if m.kind == "E" and m.body["ev"] == "skill_state"]
    assert moves == [("idle", "engage"), ("engage", "travel")]
    assert [m.body for m in session if m.kind == "R"] == [
        {"job": "j_7a1", "skill": "goto", "ok": False, "err": "E_STATE", "msg": "interrupted by a restart"}]
