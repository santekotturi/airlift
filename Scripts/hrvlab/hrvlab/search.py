"""`hrvlab search` — rank every recipe against the displayed numbers."""

from __future__ import annotations

from pathlib import Path

import pandas as pd

from .candidates import search
from .nights import TZ, device_of, load


def run(data: Path, device: str, top: int) -> pd.DataFrame:
    records = pd.read_parquet(data / "records.parquet")
    nights = {night.wake_date.strftime("%Y-%m-%d"): night for night in load(records)}
    truth = pd.read_csv(data / "truth.csv", dtype={"wake_date": str}).set_index("wake_date")[device].dropna()

    readings = records[(records.type == "HeartRateVariabilityRMSSD") & (records.source.map(device_of) == device)]
    readings = pd.DataFrame(
        {"time": readings.start.dt.tz_convert(TZ), "end": readings.end.dt.tz_convert(TZ), "value": readings.value}
    ).sort_values("time")

    ranked = search(nights, truth, device, readings)
    ranked.to_csv(data / f"search-{device}.csv", index=False)
    pd.set_option("display.width", 250, "display.max_colwidth", 110)
    print(f"{len(truth)} {device} nights, {len(ranked):,} recipes scored")
    print(ranked.head(top).to_string())
    return ranked
