"""Collects the result files into results/summary.md, ready to paste back."""

from __future__ import annotations

import json
from pathlib import Path

SECTIONS = [
    ("s8_paths.json", "S8: paths, processes, anti-cheat traces"),
    ("install.json", "Install"),
    ("s0_log.json", "S0: log channel"),
    ("s11_inbox_host.json", "S11: inbox (host side)"),
    ("optical_calibration.json", "S1: calibration"),
    ("s1_optical.json", "S1: optical decode"),
]


def _redact(text: str) -> str:
    home = str(Path.home())
    return text.replace(home, "~").replace(home.replace("\\", "\\\\"), "~")


def run(args) -> int:
    results: Path = args.results
    parts = ["# dufleet probe results", ""]
    files = [(name, title) for name, title in SECTIONS]
    files += [(p.name, f"S3/S4: {p.stem}") for p in sorted(results.glob("s3_inject_*.json"))]
    for name, title in files:
        path = results / name
        if not path.is_file():
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        parts += [f"## {title}", "", "```json", json.dumps(data, indent=1)[:6000], "```", ""]
    parts += [
        "## From the game (copy by hand)",
        "",
        "- The probe panel's lines (A2, S0, S11, S1, S10), as shown after each test",
        "- The output of `/b stats` after a few minutes of flight",
        "- A1: did ArchHUD fly to the `::pos` target and land? Anything odd?",
        "- S9: did the admin agree, and to what?",
        "",
    ]
    text = _redact("\n".join(parts))
    out = results / "summary.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(text)
    print(f"Saved {out}")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("report", help="collect the result files into results/summary.md")
    p.set_defaults(func=run)
