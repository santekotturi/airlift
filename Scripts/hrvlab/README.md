# hrvlab

Reverse-engineers the nightly HRV number each vendor's app shows — Apple's
**Recovery HRV** (Health → Vitals) and Fitbit's **HRV** — from an Apple Health
export, so Airlift can show both with a known error.

Everything runs locally. Health data lives in `data/`, which is gitignored.

## Workflow

```bash
cd Scripts/hrvlab
uv venv && uv pip install -e .

# 1. export.zip -> data/records.parquet + data/census.parquet (~1 min for 5 GB)
.venv/bin/hrvlab ingest ~/Downloads/export.zip --since 2026-08-01

# 2. What types and date ranges the export holds
.venv/bin/hrvlab census

# 3. Type the numbers the apps display into data/truth.csv
#    wake_date,apple,fitbit
#    2026-01-15,70,54

# 4. Score ~34k candidate recipes against them
.venv/bin/hrvlab search apple
.venv/bin/hrvlab search fitbit
```

`search` writes the full ranking to `data/search-<device>.csv`.

## What a recipe is

A nightly value is a choice along five axes, and the search tries their
product:

| Axis | Options |
|---|---|
| Night window | Apple's or Fitbit's sleep session, start/end padded −15…+30 min, whole or first/last 4 h or either half |
| Reading inclusion | by start, end, midpoint, or any overlap |
| Stages | all, asleep, NREM, deep, core, REM — scored by the same device |
| Weighting | equal, or by reading duration |
| Statistic | mean, median, 10%/20% trimmed mean, RMS, geometric mean |

A recipe scores by how many nights it reproduces *exactly* after rounding to
whole ms (how the apps display it), then by mean absolute error.

## Findings so far

**Apple Recovery HRV = the plain mean of every RMSSD reading the Watch wrote
that ends inside its sleep session.** Checked against Apple's own number on
24 nights: exact to the whole ms on 22, mean error
0.26 ms, worst 1.4 ms. Airlift uses this recipe
(`NightSamples.appleRecoveryHRV`).

| Recipe | Exact | Mean error | Worst |
|---|---:|---:|---:|
| Mean of readings *ending* in the sleep session | **22 / 24** | **0.26 ms** | 1.4 ms |
| Mean of readings *starting* in the sleep session | 18 / 24 | 0.36 ms | 1.2 ms |
| Mean of asleep readings only | 17 / 24 | 0.44 ms | 1.2 ms |
| Duration-weighted mean, asleep only | 16 / 24 | 0.47 ms | 2.1 ms |

Stage-restricted (deep, core, NREM, REM), median and trimmed recipes miss by
2–10 ms. The duration-weighted recipe matched all of the first five nights
and then fell behind on the other 19 — the reason to keep checking against
more nights rather than stopping at the first perfect fit.

Apple does not store the nightly value: the export has no record type for it,
only the `HeartRateVariabilityRMSSD` readings (algorithm version 3, ~300 s
windows, no beat-to-beat data attached). One recipe reaches 23 / 24 by stretching
the session 5 minutes past wake-up; with ~30,000 recipes tried, a single
fitted constant like that is more likely luck than Apple's rule, so it is not
used.

**Fitbit's nightly HRV is not reverse-engineered — it is read.** Google
Health's `daily-heart-rate-variability` type carries Fitbit's own nightly
`averageHeartRateVariabilityMilliseconds` (plus deep-sleep RMSSD and non-REM
heart rate), so Airlift fetches it during sync.
