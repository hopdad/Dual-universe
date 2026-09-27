import base64
import random

from dufleet.protocol import Deframer, encode_frame
from dufleet.protocol.crc import crc16


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


LONG = '{"ev":"note","data":{"text":"' + "abc|" * 60 + '"}}'


def chunk_line(bot, kind, seq, index, total, body):
    return f"@@DUB|1|{bot}|{kind}|{seq}|{index}/{total}|{crc16(body.encode()):04X}|{body}"


def test_single_line():
    d = Deframer()
    m = d.feed('log noise @@DUB|1|b1|A|3|1/1|' + f"{crc16(b'{}'):04X}" + "|{}\r\n")
    assert (m.bot, m.kind, m.seq, m.body, m.chunks) == ("b1", "A", 3, {}, 1)


def test_lines_without_a_frame_are_ignored_silently():
    d = Deframer()
    assert d.feed("Lua: hello") is None
    assert not d.dropped


def test_chunks_in_any_order():
    lines = encode_frame("b1", "E", 9, LONG, maxline=80)
    assert len(lines) > 3
    random.Random(7).shuffle(lines)
    d = Deframer()
    results = [d.feed(line) for line in lines]
    assert all(r is None for r in results[:-1])
    assert results[-1].body["data"]["text"].startswith("abc|")
    assert results[-1].chunks == len(lines)


def test_interleaved_bots_and_messages():
    a = encode_frame("b1", "E", 9, LONG, maxline=80)
    b = encode_frame("b2", "E", 9, LONG.replace("abc", "xyz"), maxline=80)
    c = encode_frame("b1", "E", 10, LONG.replace("abc", "qqq"), maxline=80)
    d = Deframer()
    out = []
    for group in zip(a, b, c, strict=True):
        for line in group:
            m = d.feed(line)
            if m:
                out.append((m.bot, m.seq, m.body["data"]["text"][:3]))
    assert sorted(out) == [("b1", 9, "abc"), ("b1", 10, "qqq"), ("b2", 9, "xyz")]


def test_repeated_lines_deliver_once():
    # the optical reader sees each frame on several passes
    lines = encode_frame("b1", "E", 9, LONG, maxline=80)
    single = encode_frame("b1", "A", 10, '{"ref":1,"e":1}')
    d = Deframer()
    delivered = [m for line in lines + lines + single + single for m in [d.feed(line)] if m]
    assert [m.seq for m in delivered] == [9, 10]
    assert d.duplicates == len(lines) + 1
    assert not d.pending and not d.dropped


def test_duplicates_are_forgotten_after_the_ttl():
    clock = Clock()
    d = Deframer(ttl=10, clock=clock)
    line = encode_frame("b1", "A", 10, '{"ref":1,"e":1}')[0]
    assert d.feed(line)
    clock.now = 10.5
    assert d.feed(line)


def test_incomplete_messages_expire_and_resend_completes_them():
    clock = Clock()
    lines = encode_frame("b1", "E", 9, LONG, maxline=80)
    d = Deframer(ttl=10, clock=clock)
    for line in lines[:-1]:
        assert d.feed(line) is None
    clock.now = 11
    d.feed("nothing")
    assert d.dropped["incomplete"] == 1 and not d.pending
    # a resend brings every chunk again; none of them count as duplicates
    delivered = [m for line in lines for m in [d.feed(line)] if m]
    assert len(delivered) == 1 and d.duplicates == 0


def test_corrupt_lines_are_counted():
    d = Deframer()
    good = encode_frame("b1", "A", 3, '{"ref":1,"e":1}')[0]
    assert d.feed(good.replace('"ref":1', '"ref":2')) is None
    assert d.feed("@@DUB|2|b1|A|3|1/1|0000|{}") is None
    assert d.dropped == {"crc mismatch": 1, "unknown version": 1}


def test_bad_payloads_are_counted():
    d = Deframer()
    assert d.feed(chunk_line("b1", "D", 1, 1, 1, "not json")) is None
    assert d.feed(chunk_line("b1", "D", 2, 1, 1, "[1,2]")) is None
    bad64 = "!!!!" * 5
    assert d.feed(chunk_line("b1", "D", 3, 1, 2, bad64)) is None
    assert d.feed(chunk_line("b1", "D", 3, 2, 2, bad64)) is None
    latin1 = base64.b64encode(b'{"msg":"\xe9"}').decode()
    assert d.feed(chunk_line("b1", "D", 4, 1, 2, latin1[:8])) is None
    assert d.feed(chunk_line("b1", "D", 4, 2, 2, latin1[8:])) is None
    assert d.dropped == {"bad json": 2, "body not an object": 1, "bad base64": 1}


def test_forget_drops_partial_messages_of_a_restarted_bot():
    lines = encode_frame("b1", "E", 9, LONG, maxline=80)
    other = encode_frame("b2", "E", 9, LONG, maxline=80)
    d = Deframer()
    d.feed(lines[0])
    d.feed(other[0])
    d.forget("b1")
    assert [k[0] for k in d.pending] == ["b2"]
