import random

import pytest

from dufleet.protocol import CommandError, FrameError, build_command, crc16, parse_command, parse_frame_line
from dufleet.protocol import generated as g


def test_build_and_parse_round_trip():
    line = build_command(3, 17, "run", "goto", "j_a1", "pos=0,2,35.3951,104.1187,285.5413", "alt=1500")
    assert line.startswith("/b 3.17 run goto j_a1 ")
    c = parse_command(line)
    assert (c.epoch, c.cseq, c.verb) == (3, 17, "run")
    assert c.named == {"skill": "goto", "job": "j_a1"}
    assert c.params == {"pos": "0,2,35.3951,104.1187,285.5413", "alt": "1500"}


def test_crc_covers_the_bytes_between_prefix_and_hash():
    line = build_command(1, 2, "setid", "hauler-1")
    core, crc = line[len("/b "):].rsplit(" #", 1)
    assert core == "1.2 setid hauler-1"
    assert int(crc, 16) == crc16(core.encode("utf-8"))


@pytest.mark.parametrize(
    "args",
    [
        ("run", "goto", "j_1", "p=::pos{0,2,1,2,3}"),  # ArchHUD would treat the line as a waypoint
        ("setid", "has space"),
        ("db", "set", "dub.x"),
        ("fly",),
    ],
)
def test_build_refuses_lines_the_bus_would_reject(args):
    with pytest.raises(CommandError):
        build_command(1, 1, *args)


def test_every_verb_in_the_schema_has_a_vector(vectors):
    assert {c["verb"] for c in vectors["commands"]} == set(g.VERBS)


def _mutations(line: str, rng: random.Random):
    chars = [chr(c) for c in range(0x20, 0x7F)] + ["é", "\t", "\n", "#", " ", "::pos"]
    for _ in range(300):
        s = list(line)
        for _ in range(rng.randint(1, 4)):
            op = rng.randrange(3)
            i = rng.randrange(len(s) + 1)
            if op == 0:
                s.insert(i, rng.choice(chars))
            elif op == 1 and s:
                del s[min(i, len(s) - 1)]
            elif s:
                s[min(i, len(s) - 1)] = rng.choice(chars)
        yield "".join(s)


def test_parser_only_ever_raises_command_error(vectors):
    rng = random.Random(1)
    seeds = [c["line"] for c in vectors["commands"]] + [c["line"] for c in vectors["command_errors"]]
    for seed in seeds:
        for text in _mutations(seed, rng):
            try:
                parse_command(text)
            except CommandError as exc:
                assert exc.code in g.ERRORS
                assert exc.code == "E_PARSE" or exc.ref >= 1


def test_frame_parser_only_ever_raises_frame_error(vectors):
    rng = random.Random(2)
    seeds = [line for f in vectors["frames"] for line in f["lines"]]
    for seed in seeds:
        for text in _mutations(seed, rng):
            try:
                parse_frame_line(text)
            except FrameError:
                pass
