"""Every plausible recipe for a nightly HRV number, scored against the
numbers the vendors' own apps display.

A recipe is (window, inclusion rule, stage filter, weighting, statistic).
Each axis is something Apple or Fitbit could reasonably have chosen; the grid
is their product. With one value per night and a handful of nights, the
score that matters is how many nights a recipe reproduces *exactly* once
rounded the way the app rounds (whole ms), then the mean absolute error.
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass

import numpy as np
import pandas as pd

from .nights import APPLE, FITBIT, Night

PADS = [pd.Timedelta(minutes=m) for m in (-15, -5, 0, 5, 15, 30)]
INCLUSION = ("start", "end", "midpoint", "overlap")
STAGES = {
    "all": None,
    "asleep": {"core", "deep", "rem"},
    "nrem": {"core", "deep"},
    "deep": {"deep"},
    "core": {"core"},
    "rem": {"rem"},
}
WEIGHTS = ("equal", "duration")
STATISTICS = ("mean", "median", "trim10", "trim20", "rms", "geomean")
#: Windows cut out of the night itself rather than the whole session.
SLICES = ("whole", "first4h", "last4h", "first-half", "second-half")


@dataclass(frozen=True)
class Recipe:
    window: str  # whose sleep defines the night: "apple" or "fitbit"
    pad_start: int  # minutes added before the window
    pad_end: int  # minutes added after it
    slice: str
    inclusion: str
    stages: str
    weight: str
    statistic: str

    @property
    def name(self) -> str:
        return (
            f"{self.window} sleep {self.pad_start:+d}/{self.pad_end:+d}m · {self.slice} · "
            f"by {self.inclusion} · {self.stages} · {self.weight} · {self.statistic}"
        )


def recipes(windows=(APPLE, FITBIT)):
    for window, pad_start, pad_end, slice_, inclusion, stages, weight, statistic in itertools.product(
        windows, PADS, PADS, SLICES, INCLUSION, STAGES, WEIGHTS, STATISTICS
    ):
        if weight == "duration" and statistic not in ("mean", "rms"):
            continue  # weighting only means something for these two
        yield Recipe(
            window,
            int(pad_start.total_seconds() // 60),
            int(pad_end.total_seconds() // 60),
            slice_,
            inclusion,
            stages,
            weight,
            statistic,
        )


def evaluate(recipe: Recipe, night: Night, device: str, readings_all: pd.DataFrame) -> float | None:
    """The recipe's value for one night, from every reading the device wrote
    (`readings_all`, not just the ones `nights` pre-cut), so padding the
    window can reach readings outside the sleep session."""
    span = night.window(recipe.window)
    if span is None:
        return None
    start = span[0] - pd.Timedelta(minutes=recipe.pad_start)
    end = span[1] + pd.Timedelta(minutes=recipe.pad_end)
    start, end = _slice(start, end, recipe.slice)

    times, ends = readings_all.time, readings_all.end
    if recipe.inclusion == "start":
        mask = (times >= start) & (times < end)
    elif recipe.inclusion == "end":
        mask = (ends > start) & (ends <= end)
    elif recipe.inclusion == "midpoint":
        mid = times + (ends - times) / 2
        mask = (mid >= start) & (mid < end)
    else:
        mask = (ends > start) & (times < end)
    readings = readings_all[mask]

    wanted = STAGES[recipe.stages]
    if wanted is not None:
        stages = night_stages(night, recipe.window, readings.time)
        readings = readings[[stage in wanted for stage in stages]]
    if readings.empty:
        return None

    values = readings.value.to_numpy(dtype=float)
    weights = (
        np.maximum((readings.end - readings.time).dt.total_seconds().to_numpy(), 1.0)
        if recipe.weight == "duration"
        else np.ones_like(values)
    )
    return statistic(values, weights, recipe.statistic)


def statistic(values: np.ndarray, weights: np.ndarray, name: str) -> float:
    if name == "mean":
        return float(np.average(values, weights=weights))
    if name == "rms":
        return float(np.sqrt(np.average(values**2, weights=weights)))
    if name == "median":
        return float(np.median(values))
    if name == "geomean":
        return float(np.exp(np.mean(np.log(np.maximum(values, 1e-6)))))
    if name.startswith("trim"):
        cut = int(name.removeprefix("trim")) / 100
        ordered = np.sort(values)
        k = int(len(ordered) * cut)
        kept = ordered[k : len(ordered) - k] if len(ordered) > 2 * k else ordered
        return float(kept.mean())
    raise ValueError(name)


def night_stages(night: Night, device: str, times: pd.Series) -> list[str]:
    from .nights import _stage_at

    return _stage_at(times, night.sleep.get(device))


def _slice(start, end, name):
    if name == "whole":
        return start, end
    four = pd.Timedelta(hours=4)
    if name == "first4h":
        return start, min(end, start + four)
    if name == "last4h":
        return max(start, end - four), end
    middle = start + (end - start) / 2
    return (start, middle) if name == "first-half" else (middle, end)


def search(nights: dict[str, Night], truth: pd.Series, device: str, readings_all: pd.DataFrame) -> pd.DataFrame:
    """Score every recipe against `truth` (wake date -> displayed value)."""
    dates = [date for date in truth.index if date in nights]
    rows = []
    for recipe in recipes():
        values = [evaluate(recipe, nights[date], device, readings_all) for date in dates]
        if any(value is None for value in values):
            continue
        predicted = np.array(values)
        actual = truth.loc[dates].to_numpy(dtype=float)
        error = predicted - actual
        rows.append(
            {
                "recipe": recipe.name,
                "exact": int(np.sum(np.round(predicted) == actual)),
                "mae": float(np.mean(np.abs(error))),
                "max_err": float(np.max(np.abs(error))),
                "bias": float(np.mean(error)),
                **{f"pred {date[5:]}": round(value, 1) for date, value in zip(dates, values)},
            }
        )
    frame = pd.DataFrame(rows)
    return frame.sort_values(["exact", "mae"], ascending=[False, True]).reset_index(drop=True)
