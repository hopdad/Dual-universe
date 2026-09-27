"""The Python codec against packages/protocol/vectors.json, the contract shared with the Lua bus."""

import base64
import binascii
import json

import pytest
from conftest import PROTOCOL, load_tool
from jsonschema import Draft202012Validator

from dufleet.protocol import (
    CommandError,
    Deframer,
    FrameError,
    crc16,
    decide,
    encode_frame,
    parse_command,
    parse_frame_line,
)
from dufleet.protocol import generated as g
from dufleet.protocol.command import _raw_line


def test_generated_constants_are_current():
    codegen = load_tool("codegen", PROTOCOL / "codegen.py")
    assert codegen.main(["--check"]) == 0


def test_vectors_are_current():
    tool = load_tool("make_vectors", PROTOCOL / "tools" / "make_vectors.py")
    assert tool.render() == (PROTOCOL / "vectors.json").read_text(encoding="utf-8")


def test_vectors_cover_the_plan(vectors):
    assert {"name": "check value", "hex": b"123456789".hex(), "crc": "29B1"} in vectors["crc16"]
    names = {f["name"] for f in vectors["frames"]}
    assert {"pipe in body", "chunked at 120", "ten or more chunks", "exactly maxline"} <= names
    assert any(len(f["lines"]) >= 10 for f in vectors["frames"])
    assert {e["code"] for e in vectors["command_errors"]} == {"E_PARSE", "E_CRC", "E_VERB", "E_ARGS"}
    assert {d["outcome"] for d in vectors["dedupe"]} == {"execute", "replay", "superseded", "stale"}


def test_crc16(vectors):
    for case in vectors["crc16"]:
        data = bytes.fromhex(case["hex"])
        assert f"{crc16(data):04X}" == case["crc"], case["name"]
        assert crc16(data) == binascii.crc_hqx(data, 0xFFFF), case["name"]


def test_base64(vectors):
    for case in vectors["base64"]:
        assert base64.b64encode(bytes.fromhex(case["hex"])).decode() == case["b64"]


def test_encode_frame(vectors):
    for case in vectors["frames"]:
        lines = encode_frame(case["bot"], case["kind"], case["seq"], case["body"], case["maxline"])
        assert lines == case["lines"], case["name"]
        assert all(len(line.encode("utf-8")) <= case["maxline"] for line in lines), case["name"]


def test_frames_decode_back_to_their_body(vectors):
    for case in vectors["frames"]:
        deframer = Deframer()
        messages = [m for m in map(deframer.feed, case["lines"]) if m is not None]
        assert len(messages) == 1, case["name"]
        m = messages[0]
        assert (m.bot, m.kind, m.seq, m.chunks) == (case["bot"], case["kind"], case["seq"], len(case["lines"]))
        assert m.body == json.loads(case["body"]), case["name"]
        assert not deframer.dropped and not deframer.pending


def test_chunk_count_is_the_smallest_that_fits(vectors):
    for case in vectors["frames"]:
        n = len(case["lines"])
        if n > 1:
            # one chunk fewer does not fit: its longest line would exceed maxline
            b64 = base64.b64encode(case["body"].encode()).decode()
            head = len(f"@@DUB|1|{case['bot']}|{case['kind']}|{case['seq']}|{n - 1}/{n - 1}|0000|")
            assert n - 1 == 1 or (n - 1) * (case["maxline"] - head) < len(b64), case["name"]


def test_encode_frame_errors(vectors):
    for case in vectors["frame_errors"]:
        with pytest.raises(FrameError) as info:
            encode_frame(case["bot"], case["kind"], case["seq"], case["body"], case["maxline"])
        assert info.value.reason == case["error"], case["name"]


def test_parse_frame_line(vectors):
    for case in vectors["frame_lines"]:
        if "error" in case:
            with pytest.raises(FrameError) as info:
                parse_frame_line(case["line"])
            assert info.value.reason == case["error"], case["name"]
        else:
            c = parse_frame_line(case["line"])
            got = {"bot": c.bot, "kind": c.kind, "seq": c.seq, "index": c.index, "total": c.total, "body": c.body}
            assert got == case["chunk"], case["name"]


def test_commands(vectors):
    for case in vectors["commands"]:
        core = " ".join([f"{case['epoch']}.{case['cseq']}", case["verb"], *case["args"]])
        assert _raw_line(core) == case["line"]
        c = parse_command(case["line"])
        assert (c.epoch, c.cseq, c.verb, list(c.args)) == (case["epoch"], case["cseq"], case["verb"], case["args"])
        assert c.named == case["named"] and c.params == case["params"], case["line"]
        assert len(case["line"]) <= g.COMMAND_MAX


def test_command_errors(vectors):
    for case in vectors["command_errors"]:
        with pytest.raises(CommandError) as info:
            parse_command(case["line"])
        e = info.value
        assert (e.code, e.ref, e.epoch) == (case["code"], case["ref"], case["epoch"]), case["name"]


def test_dedupe(vectors):
    for case in vectors["dedupe"]:
        assert decide(*case["last"], *case["cmd"]) == case["outcome"], case


def _validator(schema: dict, kind: str) -> Draft202012Validator:
    name = schema["x-kind-bodies"][kind]
    return Draft202012Validator({"$defs": schema["$defs"], "$ref": f"#/$defs/{name}"})


def test_schema_is_valid(schema):
    Draft202012Validator.check_schema(schema)
    assert set(schema["x-kind-bodies"]) == set(g.KINDS)
    assert set(schema["x-kind-bodies"].values()) <= set(schema["$defs"])
    assert set(schema["$defs"]["nack"]["properties"]["err"]["enum"]) == set(g.ERRORS)


def test_bodies(vectors, schema):
    for case in vectors["bodies"]["valid"]:
        errors = list(_validator(schema, case["kind"]).iter_errors(case["body"]))
        assert not errors, (case, errors)
    for case in vectors["bodies"]["invalid"]:
        assert not _validator(schema, case["kind"]).is_valid(case["body"]), case["why"]
