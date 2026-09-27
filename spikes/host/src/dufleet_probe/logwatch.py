"""Spike S0: does the probe's system.print output reach the client's disk log?

Tails the newest *.xml log (DU writes <record> elements with <logger>, <millis> and
<message> children; see DU-LogFramework), picks out probe lines ("@@DUB|probe|...")
and reports latency, the length sweep and the escaping test. Records holding probe
lines are saved as a fixture for the Phase 1 log tailer.
"""

from __future__ import annotations

import html
import re
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from dufleet_probe.gamepaths import candidate_log_dirs, newest_logs
from dufleet_probe.kit import save_json

PREFIX = "@@DUB|probe|"
SWEEP = (100, 200, 400, 800, 1600, 3200, 6400, 12800)
MAX_BUFFER = 4 * 1024 * 1024

_RECORD = re.compile(r"<record\b[^>]*>.*?</record>", re.S)
_MESSAGE = re.compile(r"<message>(.*?)</message>", re.S)
_MILLIS = re.compile(r"<millis>(\d+)</millis>")


def split_records(buffer: str) -> tuple[list[str], str]:
    """Complete <record> elements in buffer, and the unfinished rest to keep."""
    records, end = [], 0
    for m in _RECORD.finditer(buffer):
        records.append(m.group(0))
        end = m.end()
    rest = buffer[end:]
    start = rest.rfind("<record")
    rest = rest[start:] if start >= 0 else rest[-64:]  # keep a partial "<rec" across reads
    return records, rest


def record_message(record: str) -> str | None:
    m = _MESSAGE.search(record)
    return html.unescape(m.group(1)) if m else None


def record_millis(record: str) -> int | None:
    m = _MILLIS.search(record)
    return int(m.group(1)) if m else None


class LogTail:
    """Follows the newest log file in a set of folders, across rotation and truncation."""

    def __init__(self, dirs: list[Path], file: Path | None = None, backlog: int = 512 * 1024):
        self.dirs = dirs
        self.fixed = file
        self.path: Path | None = None
        self.offset = 0
        self.buffer = ""
        self.backlog = backlog
        self.switches: list[str] = []

    def _newest(self) -> Path | None:
        if self.fixed:
            return self.fixed
        files = newest_logs(self.dirs, limit=1)
        return files[0] if files else None

    def _open(self, path: Path, from_end: bool) -> None:
        self.path = path
        size = path.stat().st_size
        self.offset = max(0, size - self.backlog) if from_end else 0
        self.buffer = ""
        self.switches.append(str(path))

    def poll(self) -> list[str]:
        newest = self._newest()
        if newest is None:
            return []
        if self.path is None:
            self._open(newest, from_end=True)
        elif newest != self.path:
            self._open(newest, from_end=False)
        try:
            size = self.path.stat().st_size
        except OSError:
            return []
        if size < self.offset:  # truncated or replaced
            self.offset, self.buffer = 0, ""
        if size == self.offset:
            return []
        with open(self.path, "rb") as f:
            f.seek(self.offset)
            data = f.read(size - self.offset)
        self.offset += len(data)
        self.buffer += data.decode("utf-8", errors="replace")
        if len(self.buffer) > MAX_BUFFER:
            self.buffer = self.buffer[-MAX_BUFFER:]
        records, self.buffer = split_records(self.buffer)
        return records


@dataclass
class ProbeStats:
    kinds: Counter = field(default_factory=Counter)
    latencies: list[float] = field(default_factory=list)
    write_delays: list[float] = field(default_factory=list)
    sweep: dict[int, str] = field(default_factory=dict)
    hello: str | None = None
    esc: str | None = None
    lines: list[str] = field(default_factory=list)
    records: list[str] = field(default_factory=list)
    nonces: set[str] = field(default_factory=set)

    def feed(self, record: str, received: float) -> str | None:
        message = record_message(record)
        if not message or PREFIX not in message:
            return None
        line = message[message.index(PREFIX):]
        parts = line.split("|", 4)  # @@DUB, probe, kind, nonce, rest
        if len(parts) < 4:
            return None
        kind, nonce = parts[2], parts[3]
        rest = parts[4] if len(parts) > 4 else ""
        self.kinds[kind] += 1
        self.nonces.add(nonce)
        self.records.append(record)
        self.lines.append(line[:200])
        millis = record_millis(record)
        if kind == "hello":
            self.hello = line
        elif kind == "tick":
            fields = rest.split("|")
            if len(fields) >= 2:
                utc = float(fields[1])
                self.latencies.append(received - utc)
                if millis is not None:
                    self.write_delays.append(millis / 1000 - utc)
        elif kind == "len":
            claimed = int(rest.split("|", 1)[0])
            intact = line.endswith("|END") and len(line) == claimed
            self.sweep[claimed] = "intact" if intact else f"truncated to {len(line)} chars"
        elif kind == "esc":
            self.esc = line
        return line

    def summary(self) -> dict:
        def stats(values: list[float]) -> dict | None:
            if not values:
                return None
            v = sorted(values)
            return {"n": len(v), "min": round(v[0], 3), "median": round(v[len(v) // 2], 3), "max": round(v[-1], 3)}

        swept = self.kinds.get("len-start") or self.sweep
        sweep = {str(n): self.sweep.get(n, "missing") for n in SWEEP} if swept else None
        return {
            "probe_lines": sum(self.kinds.values()),
            "kinds": dict(self.kinds),
            "nonces": sorted(self.nonces),
            "hello": self.hello,
            "latency_s": stats(self.latencies),
            "log_write_delay_s": stats(self.write_delays),
            "length_sweep": sweep,
            "escape_line": self.esc,
        }


def run(args) -> int:
    dirs = candidate_log_dirs(args.log_dir)
    tail = LogTail(dirs, Path(args.log_file) if args.log_file else None, backlog=args.backlog_kb * 1024)
    stats = ProbeStats()
    records_seen = 0
    print(f"Watching logs in {[str(d) for d in dirs] or '(none found)'} for {args.duration} s. Ctrl+C stops early.")
    start = time.monotonic()
    try:
        while time.monotonic() - start < args.duration:
            records = tail.poll()
            now = time.time()
            for record in records:
                records_seen += 1
                line = stats.feed(record, now)
                if line:
                    print("  " + line[:120])
            time.sleep(0.2)
    except KeyboardInterrupt:
        print("stopped")
    summary = {"log_files": tail.switches, "records_seen": records_seen, **stats.summary()}
    if stats.records:
        fixture = args.results / "s0_records.xml"
        fixture.parent.mkdir(parents=True, exist_ok=True)
        fixture.write_text("\n".join(stats.records) + "\n", encoding="utf-8")
        summary["fixture"] = str(fixture)
    path = save_json(args.results, "s0_log.json", summary)
    print(f"records seen {records_seen}, probe lines {summary['probe_lines']}. Saved {path}")
    if records_seen and not summary["probe_lines"]:
        print("The log is being written, but no probe line reached it: Transport L looks unusable.")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("logwatch", help="S0: watch the client log for probe lines")
    p.add_argument("--duration", type=float, default=300)
    p.add_argument("--log-dir", help="folder holding the *.xml logs (default: %%LOCALAPPDATA%%\\NQ\\*\\log)")
    p.add_argument("--log-file", help="follow this file instead of the newest one")
    p.add_argument("--backlog-kb", type=int, default=512, help="also scan this much of the file's existing end")
    p.set_defaults(func=run)
