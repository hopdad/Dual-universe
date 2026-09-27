"""Command line for the probe kit: `dufleet-probe <command>` (see spikes/README.md)."""

from __future__ import annotations

import argparse
from pathlib import Path

from dufleet_probe import __version__, inbox, inject, install, logwatch, optical, paths, report
from dufleet_probe.kit import DEFAULT_RESULTS


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dufleet-probe", description="Phase 0 probe kit for mydu-fleet.")
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS,
                        help=f"folder for result files (default: {DEFAULT_RESULTS})")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)
    for module in (paths, install, logwatch, inbox, optical, inject, report):
        module.add_parser(sub)
    args = parser.parse_args(argv)
    return args.func(args) or 0
