#!/usr/bin/env python3
"""Writes packages/protocol/vectors.json from the Python reference codec.

    cd companion && uv run python ../packages/protocol/tools/make_vectors.py           write
    cd companion && uv run python ../packages/protocol/tools/make_vectors.py --check   fail if stale

The Lua bus and the Python companion are both tested against the committed file.
Change the codec or the cases here, run this, and review the diff of vectors.json:
it is the contract between the two sides.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE.parent / "vectors.json"
sys.path.insert(0, str(ROOT / "companion" / "src"))

from dufleet.protocol import (  # noqa: E402
    CommandError,
    FrameError,
    crc16,
    decide,
    encode_frame,
    parse_command,
    parse_frame_line,
)
from dufleet.protocol import generated as g  # noqa: E402
from dufleet.protocol.command import _raw_line  # noqa: E402
from dufleet.protocol.frame import _header  # noqa: E402


def crc_cases() -> list[dict]:
    cases = [
        ("check value", b"123456789"),
        ("empty", b""),
        ("one byte", b"A"),
        ("all byte values", bytes(range(256))),
        ("utf-8", "Alioth é ü 日本".encode()),
        ("command core", b"1.42 ping"),
    ]
    return [{"name": n, "hex": d.hex(), "crc": f"{crc16(d):04X}"} for n, d in cases]


def base64_cases() -> list[dict]:
    data = [b"", b"f", b"fo", b"foo", b"foob", b"fooba", b"foobar", bytes(range(256)), "日本".encode()]
    return [{"hex": d.hex(), "b64": base64.b64encode(d).decode("ascii")} for d in data]


def padded_debug(bot: str, kind: str, seq: int, maxline: int, extra: int = 0) -> str:
    """A D body whose single line is exactly maxline bytes, plus `extra` bytes."""
    head = len(_header(bot, kind, seq, 1, 1, 0))
    fill = maxline - head - len('{"msg":""}') + extra
    return '{"msg":"' + "x" * fill + '"}'


def frame_cases() -> list[dict]:
    wide = "Alioth é ü 日本 " * 4
    cases = [
        ("single line", "hauler-1", "A", 7, '{"ref":1,"e":1}', g.MAXLINE_DEFAULT),
        ("seq 0", "hauler-1", "H", 0,
         '{"boot":"k3f9a1","v":"0.1.0","epoch":0,"cseq":0,"id":"","ah":"6c95222","tr":"O","ml":400,"q":0}',
         g.MAXLINE_DEFAULT),
        ("pipe in body", "hauler-1", "E", 3, '{"ev":"note","data":{"text":"a|b||c|"}}', g.MAXLINE_DEFAULT),
        ("utf-8 single line", "hauler-1", "D", 4, json.dumps({"msg": wide}, ensure_ascii=False), g.MAXLINE_DEFAULT),
        ("exactly maxline", "b1", "D", 5, padded_debug("b1", "D", 5, 100), 100),
        ("one byte over maxline", "b1", "D", 6, padded_debug("b1", "D", 6, 100, 1), 100),
        ("utf-8 chunked because bytes exceed maxline", "b1", "D", 8,
         json.dumps({"msg": "日本語のテキスト" * 3}, ensure_ascii=False), 100),
        ("chunked at 120", "hauler-1", "E", 12,
         '{"ev":"skill_state","skill":"goto","from":"align","to":"travel","job":"j_7a1","data":{"note":"a|b|c"}}',
         120),
        ("ten or more chunks", "b", "D", 1, '{"msg":"' + "x" * 400 + '"}', 64),
        ("max seq", "Z", "T", g.SEQ_MAX, '{"v":0}', g.MAXLINE_DEFAULT),
    ]
    out = []
    for name, bot, kind, seq, body, maxline in cases:
        out.append({"name": name, "bot": bot, "kind": kind, "seq": seq, "body": body, "maxline": maxline,
                    "lines": encode_frame(bot, kind, seq, body, maxline)})
    return out


def frame_error_cases() -> list[dict]:
    cases = [
        ("maxline too small", "hauler-1", "D", 12345, '{"msg":"' + "x" * 60 + '"}', 48),
        ("body too long", "b", "D", 1, '{"msg":"' + "x" * 4000 + '"}', 64),
        ("bad bot id", "bad.bot", "A", 1, "{}", g.MAXLINE_DEFAULT),
        ("bot id too long", "b" * 17, "A", 1, "{}", g.MAXLINE_DEFAULT),
        ("unknown kind", "b", "Z", 1, "{}", g.MAXLINE_DEFAULT),
        ("seq too big", "b", "A", g.SEQ_MAX + 1, "{}", g.MAXLINE_DEFAULT),
        ("negative seq", "b", "A", -1, "{}", g.MAXLINE_DEFAULT),
    ]
    out = []
    for name, bot, kind, seq, body, maxline in cases:
        try:
            encode_frame(bot, kind, seq, body, maxline)
        except FrameError as exc:
            out.append({"name": name, "bot": bot, "kind": kind, "seq": seq, "body": body, "maxline": maxline,
                        "error": exc.reason})
        else:
            raise AssertionError(f"frame error case did not fail: {name}")
    return out


def _line(bot: str, kind: str, seq: str, index: str, body: str, crc: str | None = None, version: str = "1") -> str:
    crc = crc if crc is not None else f"{crc16(body.encode()):04X}"
    return f"{g.PREFIX}|{version}|{bot}|{kind}|{seq}|{index}|{crc}|{body}"


LOWER_BODY = '{"ref":2,"e":1}'  # its CRC has hex letters, so lowercase differs


def frame_line_cases() -> list[dict]:
    assert f"{crc16(LOWER_BODY.encode()):04x}" != f"{crc16(LOWER_BODY.encode()):04X}"
    good = _line("hauler-1", "A", "7", "1/1", '{"ref":1,"e":1}')
    cases = [
        ("plain", good),
        ("after a log prefix", "[2026-09-27 01:02:03] Lua: " + good),
        ("trailing CRLF", good + "\r\n"),
        ("pipes in body", _line("b", "E", "3", "1/1", '{"ev":"note","data":{"text":"a|b||c|"}}')),
        ("chunk 2 of 3", _line("b", "D", "9", "2/3", "eyJtc2ciOiJ4")),
        ("max chunks", _line("b", "D", "9", "99/99", "eHh4")),
        ("no frame", "Lua: hello"),
        ("too few fields", f"{g.PREFIX}|1|b|A|7|1/1|0000"),
        ("unknown version", _line("b", "A", "7", "1/1", "{}", version="2")),
        ("bad bot id", _line("bad.bot", "A", "7", "1/1", "{}")),
        ("empty bot id", _line("", "A", "7", "1/1", "{}")),
        ("unknown kind", _line("b", "X", "7", "1/1", "{}")),
        ("lowercase kind", _line("b", "a", "7", "1/1", "{}")),
        ("seq with leading zero", _line("b", "A", "07", "1/1", "{}")),
        ("seq too big", _line("b", "A", str(g.SEQ_MAX + 1), "1/1", "{}")),
        ("negative seq", _line("b", "A", "-1", "1/1", "{}")),
        ("index zero", _line("b", "A", "7", "0/1", "{}")),
        ("index above total", _line("b", "A", "7", "3/2", "{}")),
        ("too many chunks", _line("b", "A", "7", "1/100", "{}")),
        ("index leading zero", _line("b", "A", "7", "01/2", "{}")),
        ("index without slash", _line("b", "A", "7", "1-2", "{}")),
        ("lowercase crc", _line("b", "A", "7", "1/1", LOWER_BODY, crc=f"{crc16(LOWER_BODY.encode()):04x}")),
        ("crc mismatch", _line("b", "A", "7", "1/1", '{"ref":1,"e":1}', crc="0000")),
        ("short crc", _line("b", "A", "7", "1/1", "{}", crc="1D0")),
    ]
    out = []
    for name, line in cases:
        try:
            c = parse_frame_line(line)
        except FrameError as exc:
            out.append({"name": name, "line": line, "error": exc.reason})
        else:
            out.append({"name": name, "line": line, "chunk": {"bot": c.bot, "kind": c.kind, "seq": c.seq,
                                                              "index": c.index, "total": c.total, "body": c.body}})
    return out


def command_cases() -> list[dict]:
    # params that make the line exactly COMMAND_MAX characters long
    target = g.COMMAND_MAX - len(g.COMMAND_PREFIX) - len(" #0000")
    core, pad = "1.99 run patrol j_pad", []
    while len(core) < target:
        key = f"k{len(pad)}="
        size = min(target - len(core) - 1 - len(key), 120)
        assert size >= 1, "padding does not fit"
        pad.append(key + "p" * size)
        core += " " + pad[-1]
    cases = [
        (1, 1, "ping", []),
        (1, 2, "status", []),
        (1, 3, "cancel", []),
        (1, 4, "cancel", ["j_7a1"]),
        (1, 5, "pause", []),
        (1, 6, "resume", []),
        (1, 7, "setid", ["hauler-1"]),
        (1, 8, "resend", ["0"]),
        (1, 9, "resend", ["4294967295"]),
        (1, 42, "run", ["goto", "j_7a1", "pos=0,2,35.3951,-104.1187,285.5413", "speed=900"]),
        (1, 43, "run", ["patrol", "j_p1"]),
        (1, 44, "db", ["get", "dub.wps.home"]),
        (1, 45, "db", ["set", "dub.cfg.tick", "0.25"]),
        (1, 46, "db", ["del", "dub.job"]),
        (1, 47, "cal", ["on"]),
        (1, 48, "cal", ["off"]),
        (1, 49, "relay", ["dufleet-w1", "eyJ2IjoicGluZyJ9"]),
        (2, 1, "ping", []),
        (g.EPOCH_MAX, g.CSEQ_MAX, "ping", []),
        (1, 99, "run", ["patrol", "j_pad", *pad]),
    ]
    out = []
    for epoch, cseq, verb, args in cases:
        line = _raw_line(" ".join([f"{epoch}.{cseq}", verb, *args]))
        c = parse_command(line)
        out.append({"epoch": epoch, "cseq": cseq, "verb": verb, "args": args, "line": line,
                    "named": c.named, "params": c.params})
    assert len(out[-1]["line"]) == g.COMMAND_MAX, len(out[-1]["line"])
    return out


def command_error_cases() -> list[dict]:
    def ok(core: str) -> str:
        return _raw_line(core)

    long_core = "1.10 setid " + "a" * 16
    too_long = ok("1.10 run patrol j_1 " + " ".join(f"k{i}=" + "v" * 40 for i in range(5)))
    cases = [
        ("missing prefix", ok("1.1 ping")[1:]),
        ("uppercase prefix", "/B" + ok("1.1 ping")[2:]),
        ("no space after /b", "/b" + ok("1.1 ping")[3:]),
        ("leading space", " " + ok("1.1 ping")),
        ("line too long", too_long),
        ("tab", ok("1.1\tping")),
        ("non-ascii", ok("1.1 setid hé")),
        ("double quote", ok('1.1 setid "a"')),
        ("backslash", ok("1.1 setid a\\b")),
        ("missing crc", "/b 1.1 ping"),
        ("lowercase crc", "/b 1.1 ping #" + f"{crc16(b'1.1 ping'):04x}"),
        ("short crc", "/b 1.1 ping #ABC"),
        ("no space before crc", "/b 1.1 ping#" + f"{crc16(b'1.1 ping'):04X}"),
        ("hash inside", ok("1.5 db set dub.x a#b")),
        ("::pos", ok("1.5 run goto j_1 p=::pos{0,2,1,2,3}")),
        ("double space", ok("1.5  ping")),
        ("trailing space", ok("1.5 ping ")),
        ("header only", ok("1.5")),
        ("header without dot", ok("15 ping")),
        ("epoch leading zero", ok("01.5 ping")),
        ("cseq leading zero", ok("1.05 ping")),
        ("epoch zero", ok("0.5 ping")),
        ("cseq zero", ok("1.0 ping")),
        ("epoch too big", ok(f"{g.EPOCH_MAX + 1}.1 ping")),
        ("cseq too big", ok(f"1.{g.CSEQ_MAX + 1} ping")),
        ("cseq eleven digits", ok("1.12345678901 ping")),
        ("negative cseq", ok("1.-5 ping")),
        ("crc mismatch", "/b 3.77 ping #0000"),
        ("crc mismatch on max header", f"/b {g.EPOCH_MAX}.{g.CSEQ_MAX} ping #0000"),
        ("unknown verb", ok("1.6 fly")),
        ("uppercase verb", ok("1.6 PING")),
        ("verb with digit", ok("1.6 ping2")),
        ("ping with argument", ok("1.7 ping x")),
        ("setid missing", ok("1.7 setid")),
        ("setid too long", ok(long_core + "a")),
        ("setid bad character", ok("1.7 setid hauler.1")),
        ("resend negative", ok("1.7 resend -1")),
        ("resend leading zero", ok("1.7 resend 01")),
        ("resend missing", ok("1.7 resend")),
        ("run unknown skill", ok("1.8 run fly j_1")),
        ("run bad job", ok("1.8 run goto job1")),
        ("run missing job", ok("1.8 run goto")),
        ("run param without =", ok("1.8 run goto j_1 speed")),
        ("run param uppercase key", ok("1.8 run goto j_1 Speed=9")),
        ("run param empty value", ok("1.8 run goto j_1 speed=")),
        ("run param key starts with digit", ok("1.8 run goto j_1 1a=2")),
        ("run param key too long", ok("1.8 run goto j_1 " + "k" * 17 + "=1")),
        ("run param value too long", ok("1.8 run goto j_1 k=" + "v" * 121)),
        ("run duplicate param", ok("1.8 run goto j_1 a=1 a=2")),
        ("db set without value", ok("1.9 db set dub.x")),
        ("db get with value", ok("1.9 db get dub.x 1")),
        ("db del with value", ok("1.9 db del dub.x 1")),
        ("db bad op", ok("1.9 db put dub.x 1")),
        ("db key without prefix", ok("1.9 db get x.y")),
        ("db key empty after prefix", ok("1.9 db get dub.")),
        ("db key uppercase", ok("1.9 db get dub.X")),
        ("cal bad state", ok("1.9 cal maybe")),
        ("cal missing", ok("1.9 cal")),
        ("relay channel too long", ok("1.9 relay " + "c" * 65 + " eyJ9")),
        ("relay bad base64", ok("1.9 relay w1 ab=c")),
        ("cancel two jobs", ok("1.9 cancel j_1 j_2")),
        ("cancel bad job", ok("1.9 cancel 7")),
    ]
    out = []
    for name, line in cases:
        try:
            parse_command(line)
        except CommandError as exc:
            out.append({"name": name, "line": line, "code": exc.code, "ref": exc.ref, "epoch": exc.epoch})
        else:
            raise AssertionError(f"command error case did not fail: {name}")
    return out


def dedupe_cases() -> list[dict]:
    cases = [
        ((0, 0), (1, 1)),
        ((1, 5), (1, 6)),
        ((1, 5), (1, 9)),
        ((1, 5), (1, 5)),
        ((1, 5), (1, 4)),
        ((1, 5), (2, 1)),
        ((2, 1), (1, 9)),
        ((3, 7), (2, 7)),
        ((1, g.CSEQ_MAX), (1, g.CSEQ_MAX)),
        ((g.EPOCH_MAX, 1), (g.EPOCH_MAX, 2)),
    ]
    return [{"last": list(last), "cmd": list(cmd), "outcome": decide(*last, *cmd)} for last, cmd in cases]


def body_cases() -> dict:
    valid = [
        ("H", {"boot": "k3f9a1", "v": "0.1.0", "epoch": 1, "cseq": 42, "id": "hauler-1", "ah": "6c95222",
               "tr": "O", "ml": 400, "q": 0}),
        ("H", {"boot": "k3f9", "v": "0.1.0", "epoch": 0, "cseq": 0}),
        ("T", {"w": [-123456.5, 98765.25, 42.0], "v": 12.4, "alt": 285.5, "b": 2, "g": [35.3951, 104.1187],
               "fuel": {"atmo": 0.82, "space": 1, "rocket": 0}, "cargo": 0.41, "st": "goto:travel",
               "ap": "altitude_hold"}),
        ("T", {}),
        ("E", {"ev": "skill_state", "skill": "goto", "from": "align", "to": "travel", "job": "j_7a1"}),
        ("A", {"ref": 1042, "e": 1}),
        ("A", {"ref": 1042, "e": 1, "job": "j_7a1"}),
        ("A", {"ref": 1042, "e": 1, "dup": True}),
        ("N", {"ref": 1042, "e": 1, "err": "E_BUSY", "msg": "skill mine_loop running"}),
        ("N", {"ref": 0, "e": 0, "err": "E_PARSE"}),
        ("R", {"job": "j_7a1", "skill": "goto", "ok": True, "data": {"dist": 3.2, "t": 184}}),
        ("R", {"job": "j_7a1", "skill": "goto", "ok": False, "err": "E_FUEL", "msg": "atmo fuel 3%"}),
        ("D", {"msg": "tick overrun"}),
    ]
    invalid = [
        ("H", {"v": "0.1.0", "epoch": 0, "cseq": 0}, "missing boot"),
        ("H", {"boot": "k3f9", "v": "0.1.0", "epoch": 0, "cseq": 0, "extra": 1}, "unknown field"),
        ("H", {"boot": "k3f9", "v": "0.1", "epoch": 0, "cseq": 0}, "version not semver"),
        ("T", {"w": [1, 2]}, "position needs three numbers"),
        ("T", {"cargo": 1.5}, "cargo ratio above 1"),
        ("E", {"ev": "Skill-State"}, "bad event name"),
        ("A", {"ref": 1}, "missing epoch"),
        ("N", {"ref": 1, "e": 1, "err": "E_NOPE"}, "unknown error code"),
        ("R", {"job": "j_1", "skill": "goto"}, "missing ok"),
        ("D", {"msg": "x" * 301}, "message too long"),
    ]
    return {
        "valid": [{"kind": k, "body": b} for k, b in valid],
        "invalid": [{"kind": k, "body": b, "why": w} for k, b, w in invalid],
    }


def build() -> dict:
    return {
        "about": "Generated by packages/protocol/tools/make_vectors.py from the Python reference codec. "
                 "The Lua and Python tests run against it. Do not edit by hand.",
        "version": g.VERSION,
        "crc16": crc_cases(),
        "base64": base64_cases(),
        "frames": frame_cases(),
        "frame_errors": frame_error_cases(),
        "frame_lines": frame_line_cases(),
        "commands": command_cases(),
        "command_errors": command_error_cases(),
        "dedupe": dedupe_cases(),
        "bodies": body_cases(),
    }


def render() -> str:
    return json.dumps(build(), indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if vectors.json is out of date")
    args = parser.parse_args(argv)
    text = render()
    current = OUT.read_text(encoding="utf-8") if OUT.exists() else None
    if current == text:
        return 0
    if args.check:
        print(f"out of date: {OUT.relative_to(ROOT)}", file=sys.stderr)
        print("run: cd companion && uv run python ../packages/protocol/tools/make_vectors.py", file=sys.stderr)
        return 1
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
