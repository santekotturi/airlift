"""Print the record-type census written by `ingest`."""

from __future__ import annotations

from pathlib import Path

import pandas as pd


def show(data: Path) -> None:
    census = pd.read_parquet(data / "census.parquet")
    pd.set_option("display.width", 200, "display.max_rows", 500, "display.max_colwidth", 80)
    census["first"] = census["first"].astype(str).str[:10]
    census["last"] = census["last"].astype(str).str[:10]
    print(census[["type", "count", "first", "last", "sources"]].to_string(index=False))
