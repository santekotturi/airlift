"""`hrvlab <command>` — see README.md for the workflow."""

from __future__ import annotations

import argparse
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"


def main() -> None:
    parser = argparse.ArgumentParser(prog="hrvlab")
    commands = parser.add_subparsers(dest="command", required=True)

    ingest = commands.add_parser("ingest", help="export.zip -> Parquet")
    ingest.add_argument("zip", type=Path)
    ingest.add_argument("--since", default="2026-08-01", help="first day of the analysis window")

    commands.add_parser("census", help="every record type in the export, with date range")

    search = commands.add_parser("search", help="rank nightly-HRV recipes against data/truth.csv")
    search.add_argument("device", choices=["apple", "fitbit"])
    search.add_argument("--top", type=int, default=25)

    args = parser.parse_args()
    if args.command == "ingest":
        from .ingest import ingest as run

        run(args.zip.expanduser(), DATA, args.since)
    elif args.command == "census":
        from .census import show

        show(DATA)
    elif args.command == "search":
        from .search import run

        run(DATA, args.device, args.top)


if __name__ == "__main__":
    main()
