import html
import os
import time

import pytest

from dufleet_probe import logwatch


def rec(message: str, millis: int = 1790000000500) -> str:
    return (f"<record>\n  <date>2026-09-27T10:00:00</date>\n  <millis>{millis}</millis>\n"
            f"  <logger>lua</logger>\n  <message>{html.escape(message)}</message>\n</record>")


def sweep_line(n: int) -> str:
    head = f"@@DUB|probe|len|abc123|{n}|"
    return head + "x" * (n - len(head) - 4) + "|END"


def test_split_records_keeps_partial_record():
    a, b = rec("one"), rec("two")
    records, rest = logwatch.split_records(a + "\n" + b[:25])
    assert records == [a]
    records, rest = logwatch.split_records(rest + b[25:] + "\n")
    assert records == [b]


def test_message_is_unescaped():
    assert logwatch.record_message(rec('a <b> & "c"')) == 'a <b> & "c"'
    assert logwatch.record_millis(rec("x", millis=42)) == 42


def test_probe_stats_summary():
    stats = logwatch.ProbeStats()
    received = 1790000001.0
    stats.feed(rec("[Lua] @@DUB|probe|hello|abc123|v=0.1.0|limit=500000|io=nil"), received)
    stats.feed(rec("@@DUB|probe|tick|abc123|1|1790000000.250"), received)
    stats.feed(rec("@@DUB|probe|len-start|abc123|8"), received)
    stats.feed(rec(sweep_line(100)), received)
    stats.feed(rec(sweep_line(200)[:150]), received)
    stats.feed(rec('@@DUB|probe|esc|abc123|<>&"\'\té€✓|END'), received)
    stats.feed(rec("an unrelated line"), received)
    s = stats.summary()
    assert s["probe_lines"] == 6 and s["kinds"]["tick"] == 1 and s["nonces"] == ["abc123"]
    assert s["hello"].startswith("@@DUB|probe|hello|")
    assert s["latency_s"]["median"] == pytest.approx(0.75)
    assert s["log_write_delay_s"]["median"] == pytest.approx(0.25)
    assert s["length_sweep"]["100"] == "intact"
    assert s["length_sweep"]["200"] == "truncated to 150 chars"
    assert s["length_sweep"]["400"] == "missing"
    assert s["escape_line"] == '@@DUB|probe|esc|abc123|<>&"\'\té€✓|END'


def test_logtail_follows_appends_and_rotation(tmp_path):
    first = tmp_path / "log_a.xml"
    first.write_text(rec("@@DUB|probe|tick|n|1|1.0") + "\n", encoding="utf-8")
    tail = logwatch.LogTail([tmp_path])
    assert len(tail.poll()) == 1  # the existing end of the file is scanned too
    partial = rec("later") + "\n"
    with open(first, "a", encoding="utf-8") as f:
        f.write(partial[:30])
    assert tail.poll() == []
    with open(first, "a", encoding="utf-8") as f:
        f.write(partial[30:])
    assert [logwatch.record_message(r) for r in tail.poll()] == ["later"]
    second = tmp_path / "log_b.xml"
    second.write_text(rec("rotated") + "\n", encoding="utf-8")
    future = time.time() + 5
    os.utime(second, (future, future))
    assert [logwatch.record_message(r) for r in tail.poll()] == ["rotated"]
    assert tail.switches == [str(first), str(second)]


def test_logtail_survives_truncation(tmp_path):
    log = tmp_path / "log.xml"
    log.write_text(rec("one") + "\n" + rec("two") + "\n", encoding="utf-8")
    tail = logwatch.LogTail([tmp_path])
    assert len(tail.poll()) == 2
    log.write_text(rec("fresh") + "\n", encoding="utf-8")  # shorter than before
    assert [logwatch.record_message(r) for r in tail.poll()] == ["fresh"]


def test_non_utf8_bytes_do_not_break_parsing(tmp_path):
    log = tmp_path / "log.xml"
    log.write_bytes(b"<record><message>bad \xff byte</message></record>\n")
    tail = logwatch.LogTail([tmp_path])
    assert logwatch.record_message(tail.poll()[0]) == "bad � byte"
