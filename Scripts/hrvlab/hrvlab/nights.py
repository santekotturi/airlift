"""Cut the records into nights, keyed by the date you woke up.

Each night carries, per device, the sleep hypnogram and the RMSSD readings
that fall inside the night window, every reading labelled with the stage the
*same device* scored it in. Apple's Vitals app and Fitbit's app each file a
night under its wake date, so that is the key here too.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

TZ = "America/Los_Angeles"

APPLE = "apple"
FITBIT = "fitbit"

ASLEEP = {"AsleepCore": "core", "AsleepDeep": "deep", "AsleepREM": "rem", "AsleepUnspecified": "core"}
#: Sleep segments closer than this belong to one session.
SESSION_GAP = pd.Timedelta(minutes=90)


def device_of(source: str) -> str | None:
    """Which instrument a record came from. Airlift's and Google Health's
    writes are both the Fitbit; the Watch's sources all contain "Watch"."""
    if source in ("Airlift", "Google Health"):
        return FITBIT
    if "Watch" in source:
        return APPLE
    return None


@dataclass
class Night:
    wake_date: pd.Timestamp
    #: Per device: DataFrame of asleep/awake segments (start, end, stage).
    sleep: dict[str, pd.DataFrame] = field(default_factory=dict)
    #: Per device: DataFrame of RMSSD readings (time, end, value, stage).
    rmssd: dict[str, pd.DataFrame] = field(default_factory=dict)

    def window(self, device: str) -> tuple[pd.Timestamp, pd.Timestamp] | None:
        segments = self.sleep.get(device)
        if segments is None or segments.empty:
            return None
        return segments.start.min(), segments.end.max()


def load(records: pd.DataFrame) -> list[Night]:
    records = records.copy()
    records["device"] = records.source.map(device_of)
    records = records[records.device.notna()]
    records["start"] = records.start.dt.tz_convert(TZ)
    records["end"] = records.end.dt.tz_convert(TZ)

    sleep = records[(records.type == "SleepAnalysis") & records.category.notna()].copy()
    sleep["stage"] = sleep.category.str.removeprefix("HKCategoryValueSleepAnalysis")
    sleep = sleep[sleep.stage != "InBed"]
    # Airlift and Google Health both write the Fitbit's night; prefer Google
    # Health's own copy where both exist, Airlift's where it is the only one.
    sleep = _one_fitbit_writer(sleep)

    rmssd = records[records.type == "HeartRateVariabilityRMSSD"][["device", "start", "end", "value"]]

    nights: dict[pd.Timestamp, Night] = {}
    for device, segments in sleep.groupby("device"):
        for session in _sessions(segments.sort_values("start")):
            asleep = session[session.stage.isin(ASLEEP)]
            if asleep.empty or (asleep.end - asleep.start).sum() < pd.Timedelta(hours=3):
                continue  # a nap, not the night
            wake = session.end.max().normalize()
            night = nights.setdefault(wake, Night(wake))
            if device in night.sleep:  # keep the longer session per wake date
                if _asleep(night.sleep[device]) >= _asleep(session):
                    continue
            night.sleep[device] = session[["start", "end", "stage"]].reset_index(drop=True)

    for night in nights.values():
        for device in (APPLE, FITBIT):
            span = night.window(device) or night.window(APPLE) or night.window(FITBIT)
            if span is None:
                continue
            start, end = span
            readings = rmssd[(rmssd.device == device) & (rmssd.start >= start) & (rmssd.start < end)]
            readings = readings.rename(columns={"start": "time"})[["time", "end", "value"]].copy()
            readings["stage"] = _stage_at(readings.time, night.sleep.get(device))
            night.rmssd[device] = readings.reset_index(drop=True)

    return [nights[key] for key in sorted(nights)]


def _one_fitbit_writer(sleep: pd.DataFrame) -> pd.DataFrame:
    fitbit = sleep[sleep.device == FITBIT]
    other = sleep[sleep.device != FITBIT]
    fitbit = fitbit.assign(wake=fitbit.end.dt.normalize())
    keep = []
    for _, group in fitbit.groupby("wake"):
        google = group[group.source == "Google Health"]
        keep.append(google if not google.empty else group)
    return pd.concat([other, *keep]) if keep else other


def _sessions(segments: pd.DataFrame):
    current, last_end = [], None
    for index, row in segments.iterrows():
        if last_end is not None and row.start - last_end > SESSION_GAP:
            yield segments.loc[current]
            current = []
        current.append(index)
        last_end = row.end if last_end is None else max(last_end, row.end)
    if current:
        yield segments.loc[current]


def _asleep(session: pd.DataFrame) -> pd.Timedelta:
    asleep = session[session.stage.isin(ASLEEP)]
    return (asleep.end - asleep.start).sum()


def _stage_at(times: pd.Series, segments: pd.DataFrame | None) -> list[str]:
    if segments is None or segments.empty:
        return ["none"] * len(times)
    starts = segments.start.to_numpy()
    ends = segments.end.to_numpy()
    stages = [ASLEEP.get(stage, "awake") for stage in segments.stage]
    labels = []
    for time in times.to_numpy():
        hits = np.nonzero((starts <= time) & (time < ends))[0]
        labels.append(stages[hits[-1]] if len(hits) else "gap")
    return labels
