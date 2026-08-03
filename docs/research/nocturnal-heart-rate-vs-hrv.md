# Sampling density, not signal quality, limits Apple Watch recovery metrics

**A single-subject comparison of Apple Watch and Fitbit Air overnight recovery data, and why nocturnal heart rate beats Apple's HRV.**

Sante Kotturi · August 2026 · single subject, n = 37 paired nights

---

## Summary

Apple Watch overnight HRV is widely reported to be noisy. This study quantifies how noisy, isolates the cause, and tests a specific proposal from the sports-science literature — that athletic recovery is best read from HRV during the last bout of deep (N3) sleep.

Four findings, in order of how much they changed the conclusion:

1. **The last-deep-bout target is unreachable on an Apple Watch.** Apple samples HRV every 120 minutes. The last deep bout in this subject lasts a median of 7.7 minutes. Expected yield: **0.06 samples per night** — roughly one night in sixteen. Even the Fitbit Air, sampling ~20× more often, lands only 3.1 samples there and misses the window entirely on 7 of 41 nights.

2. **Restricting Apple's HRV to NREM makes it worse, not better.** Level agreement with the reference falls from 0.732 to 0.711 and change agreement from 0.720 to 0.632, because restriction removes a third of an already-tiny sample (3.9 → 2.7 windows per night). Physiological homogeneity is real but costs more than it returns.

3. **Nocturnal heart rate over the same NREM zone substantially outperforms reconstructed HRV**: Spearman **0.849** on levels and **0.810** on night-to-night changes, versus 0.732 / 0.720 for the best HRV pipeline, with split-half reliability of **0.984** against 0.539.

4. **That advantage is almost entirely a sampling-density effect.** Thinned to the HRV sampling rate of 4 samples per night, heart rate scores 0.722 / 0.616 — statistically indistinguishable from HRV. The watch measures heart rate **17× more often** than HRV inside the sleep window, and that is the whole difference.

The practical recommendation is a combined index of pooled RMSSD and NREM mean heart rate, which reaches **0.894 on levels and 0.897 on changes** — but the general lesson is that on a wrist wearable, *how often you measure* dominates *what you measure*.

> **This is n = 1.** Every number below describes one person, one Apple Watch Ultra 2, and 37 paired nights. Nothing here is a population claim, and the Fitbit is a reference, not ground truth.

---

## 1. Why this analysis was possible

Comparing two wearables usually means exporting from two ecosystems and reconciling timestamps by hand. Here both devices write into the same store: the Apple Watch natively, and the Fitbit Air through [Airlift](../../README.md), which bridges Google Health data into HealthKit with full stage detail. A single `export.zip` then contains both instruments measuring the same nights, in the same schema, with the same clock.

That is the only reason a night-by-night paired comparison is available at all, and it is why this paper lives in this repository.

The analysis code is a separate Python library, `recoverylab`, described in [§9](#9-reproducing-this).

### The two instruments

| | Apple Watch Ultra 2 | Fitbit Air |
|---|---|---|
| HRV metric published | SDNN, ~60 s window | proprietary (RMSSD-like) |
| Overnight HRV samples | **3.9 / night** | **92 / night** |
| Overnight HR samples | **67 / night** (core+deep) | n/a for this comparison |
| Sampling cadence | every 120 min (documented) | ~5 min |

Apple's cadence is not inferred. Apple's own white paper, *Using Apple Watch to measure heart rate, calorimetry, and activity* (November 2024), states:

> "The default tachogram measurement cadence is every four hours, increasing to two hours or 15 minutes when a user enables irregular rhythm notifications or AFib History, respectively."

The observed median gap between consecutive HRV samples in this export is 3.73 h in 2021 and exactly 2.00 h from 2023 onward, matching the documented default and then the irregular-rhythm cadence. **Apple's stated sampling behaviour is confirmed exactly.** The ~60 s window length, which Apple does not document anywhere, is confirmed empirically: median record span 59 s, median beat-derived duration 57.1 s (n = 13,732).

---

## 2. Method

**Study window.** 2026-06-05 to 2026-07-31, the overlap period where both devices recorded. 37 nights have a usable value from both. The window sits entirely inside the Apple Watch Ultra 2 era, so no result mixes hardware generations.

**Sleep window.** Both devices are scored inside one canonical window per night — the union of their sleep periods — so a disagreement in HRV cannot simply be a disagreement about bedtime. The first 30 minutes are trimmed: heart rate is still falling at sleep onset, and with ~4 samples a night one contaminated sample is a quarter of the evidence.

**Sleep staging.** Stages come from the Apple Watch's own hypnogram, not the Fitbit's. This is deliberate — the deployment scenario being tested is *wearing only the Apple Watch*, so it must use only what the watch knows. Note that "Deep" in HealthKit corresponds to AASM **N3**; the "stage 4" of the older Rechtschaffen & Kales scheme was merged into N3 in 2007.

**HRV reconstruction.** HealthKit stores the raw beat-to-beat intervals alongside each published SDNN value. Apple documents this explicitly:

> "Within HealthKit, SDNN is stored alongside the sequence of individual beat-to-beat measurements, used to calculate other HRV metrics."

Those intervals are re-extracted, artifact-corrected (range filter plus the Malik 20% criterion applied against the last *accepted* interval, so a single spike does not cascade), and RMSSD is recomputed per window, then pooled across the night weighted by beat count. Recomputing RMSSD from the stored beats is the documented purpose of the field, not a workaround.

**Scoring.** Every candidate is scored against the Fitbit's nightly HRV on two axes: agreement on **levels** (Spearman across nights) and agreement on **night-to-night changes** (Spearman of consecutive-night differences, log domain). The change axis matters more — it removes each device's constant offset and each person's stable baseline, leaving only what a recovery app actually acts on. All targets are oriented so higher means better recovery; heart rate is negated accordingly.

---

## 3. The last-deep-bout hypothesis

A recurring claim in applied sports science is that the cleanest autonomic recovery reading comes from the final bout of slow-wave sleep — physiologically homogeneous, maximally parasympathetic, furthest from sleep-onset artifacts. If true, it is exactly the window a recovery metric should target.

The obstacle is arithmetic.

**Deep-sleep architecture (this subject):**

| Staging source | Nights | Bouts / night | Median bout | Median *last* bout | Total deep / night |
|---|---:|---:|---:|---:|---:|
| Apple Watch | 60 | 5.42 | 6.5 min | **7.7 min** | 48.3 min |
| Fitbit Air | 48 | 4.06 | 15.5 min | 12.8 min | 75.2 min |

**What a 120-minute cadence can deliver:**

| Target window | Minutes / night | Expected HRV samples |
|---|---:|---:|
| All deep sleep | 48.3 | **0.40** |
| Last deep bout | 7.7 | **0.06** |

The prediction is confirmed by observation: the Apple Watch actually recorded **0.36** HRV samples per night in deep sleep (20 samples across 55 nights, present on only 19 of them). Predicted 0.40, observed 0.36. **Apple's sampler is effectively stage-blind** — it fires on a clock, not on physiology, and deep sleep gets its proportional share and nothing more.

A metric that yields a value on one night in sixteen is not a metric. The hypothesis fails not because it is physiologically wrong but because the instrument cannot reach the window.

### Testing the hypothesis where it *can* be tested

Whether stage targeting is a good idea is a separate question from whether Apple can execute it. The Fitbit's 92 samples/night can resolve individual bouts, and it provides its own whole-night value as a comparator — so the test runs entirely within one device, with no cross-device confound:

| Restriction | Samples / night | Nights with a value | Spearman vs whole night | Median abs. difference |
|---|---:|---:|---:|---:|
| Whole night | 92.1 | 41 / 41 | — | — |
| Core + deep | 65.0 | 41 / 41 | **0.983** | 3.4% |
| Deep only | 13.6 | 41 / 41 | 0.887 | 5.5% |
| Last deep bout | 3.1 | **34 / 41** | 0.773 | 9.6% |

Two things follow. First, **core+deep is nearly interchangeable with the whole night** (0.983, 3.4% median difference) — so the homogeneity argument, whatever its physiological merit, buys almost nothing at the level of a nightly summary. Second, the last-deep-bout value is *less* stable than the whole-night value, not more: restricting to 3 samples introduces more sampling noise than it removes physiological heterogeneity, and it fails to produce a value at all on 17% of nights.

Even given a sensor that samples 20× faster than Apple's, the last-deep-bout target does not improve on simply using the whole night.

---

## 4. Stage restriction on the Apple Watch makes things worse

Applying the same restriction to the Apple Watch, scored against the Fitbit reference:

| Apple HRV restriction | n | Windows / night | Spearman (level) | Spearman (change) |
|---|---:|---:|---:|---:|
| Whole sleep window | 37 | 3.89 | **0.732** | **0.720** |
| Core + deep | 37 | 2.67 | 0.711 | 0.632 |
| Core only | 35 | 2.44 | 0.585 | 0.574 |
| Deep only | 13 | 1.05 | *0.742* | *not interpretable* |

Every restriction that meaningfully reduces the sample count degrades the result. The deep-only row is shown for completeness but must not be read as a success: it survives on 13 nights and yields only 3 usable consecutive-night pairs, so its change statistic is an artifact of tiny n rather than a finding.

The pattern is consistent with §3. Stage restriction is a trade — homogeneity bought with sample count — and at 4 samples a night the Apple Watch cannot afford the price.

---

## 5. Heart rate: the same target zone, seventeen times the data

Heart rate is sampled far more densely than HRV inside the same sleep window:

| Stage | Apple Watch HR samples / night |
|---|---:|
| Core | 56.8 |
| Deep | 10.7 |
| REM | 31.5 |
| **Core + deep (NREM)** | **67.5** |

Compare against 3.9 HRV windows per night over the same period: a **17× density advantage** for a signal from the same sensor, on the same wrist, over the same nights.

Scored against the Fitbit reference:

| Apple-side metric | n | Spearman (level) | 95% CI | Spearman (change) |
|---|---:|---:|:---:|---:|
| Pooled RMSSD (HRV, whole window) | 37 | 0.732 | 0.51 – 0.84 | 0.720 |
| Mean HR, whole sleep window | 37 | 0.837 | 0.73 – 0.92 | 0.761 |
| Mean HR, deep only | 37 | 0.735 | 0.56 – 0.86 | 0.722 |
| **Mean HR, core + deep (NREM)** | 37 | **0.849** | 0.74 – 0.92 | **0.810** |
| **Combined RMSSD + NREM HR** | 37 | **0.894** | 0.78 – 0.94 | **0.897** |
| Combined, causal standardisation | 27 | 0.873 | 0.77 – 0.95 | 0.882 |

Note that NREM restriction *helps* heart rate (0.837 → 0.849 level, 0.761 → 0.810 change) while it *hurt* HRV. This is the same trade seen from the other side: heart rate has 67 samples to spend, so it can afford to discard REM and keep a homogeneous zone. Restricting further to deep only drops it to 10.7 samples/night and performance falls back to 0.735 — the trade turns unprofitable at exactly the point sample count becomes scarce.

The combined index is the z-score of log pooled RMSSD plus the z-score of negated log NREM heart rate. Because full-sample standardisation peeks at the future through its mean and standard deviation, a causal version is reported alongside it, standardising each night using only prior nights. It costs 10 nights of warm-up and about 0.02 of correlation — the combination is not an artifact of the leak.

---

## 6. The result that reframes everything: it is density, not heart rate

An obvious objection to §5 is that averaging 67 samples is simply more stable than averaging 4, regardless of what is being averaged. The right test is to thin the heart rate to the HRV sampling density and rerun. Each thinning is averaged over 25 random draws.

| HR samples / night | Spearman (level) | Spearman (change) | Split-half reliability |
|---:|---:|---:|---:|
| 2 | 0.676 | 0.573 | 0.632 |
| **4** *(matches HRV)* | **0.722** | **0.616** | **0.789** |
| 8 | 0.792 | 0.713 | 0.879 |
| 16 | 0.815 | 0.769 | 0.938 |
| 32 | 0.837 | 0.811 | 0.967 |
| All (~68) | 0.849 | 0.810 | 0.984 |
| *(pooled RMSSD, 3.9/night, for reference)* | *0.732* | *0.720* | *0.539* |

At matched sampling density, **heart rate and HRV perform the same** — 0.722 / 0.616 against 0.732 / 0.720. Heart rate retains a reliability edge (0.789 vs 0.539, consistent with it being a first-moment statistic where HRV is a second-moment one, and so less sensitive to individual bad beats) but no agreement advantage whatsoever.

**Nocturnal heart rate does not win because it is a better recovery signal. It wins because Apple measures it 17× more often.** Every conclusion in §5 is downstream of a scheduling decision in watchOS, not of physiology.

This also predicts the fix: if Apple sampled HRV at the density it already samples heart rate, the HRV pipeline would land near 0.85 on its own. The sensor is not the bottleneck. The duty cycle is.

---

## 7. Reliability and the attenuation ceiling

Reliability here means: of the night-to-night variation in a nightly value, how much is real signal rather than measurement error? Estimated two independent ways — randomly splitting each night's samples in half and correlating the halves across nights (Spearman-Brown corrected), and decomposing within- versus between-night variance.

| Metric | Nights | Samples / night | Split-half | 95% CI | Variance method |
|---|---:|---:|---:|:---:|---:|
| Fitbit HRV | 41 | 93 | 0.983 | 0.97 – 0.99 | 0.983 |
| **Apple published SDNN** | 45 | 4 | **0.177** | −0.17 – 0.47 | 0.092 |
| Apple pooled RMSSD (recomputed) | 45 | 4 | 0.539 | 0.39 – 0.68 | 0.481 |
| **Apple NREM mean HR** | 55 | 68 | **0.984** | 0.98 – 0.99 | 0.984 |

Apple's published nightly SDNN has a reliability of **0.177**. Roughly five sixths of the night-to-night movement a user sees in that number is the watch disagreeing with itself. Recomputing RMSSD from the stored beats triples it, to 0.539.

Two noisy instruments cannot correlate beyond `sqrt(r_a × r_b)` even when measuring the same underlying quantity. That ceiling explains why post-processing cannot rescue Apple's SDNN:

| Apple metric | Its reliability | Ceiling vs Fitbit |
|---|---:|---:|
| Apple's published SDNN | 0.177 | **0.417** |
| Pooled RMSSD from raw beats | 0.539 | 0.728 |
| NREM mean HR | 0.984 | **0.983** |

The measured RMSSD result (0.732) is already *at* its ceiling of 0.728 — no smoothing, calibration or filtering can improve it, because the information is not present. NREM heart rate raises the ceiling to 0.983 and then uses about 86% of it. Raising the ceiling is the whole game.

### Is this reliability comparison fair?

Partly not, and it should be read with §6 in mind. A mean over 68 autocorrelated samples is stable almost by construction; the 0.984 figure is as much a statement about sample count as about signal. The thinning table is the honest version: at 4 samples per night, NREM HR reliability is 0.789, not 0.984. The remaining gap over RMSSD's 0.539 at equal n is the real, density-independent advantage.

---

## 8. Two controls

**Is NREM heart rate just Apple's published resting heart rate?** If so, nothing needs building — the number is already in HealthKit.

| Metric | n | Spearman (level) | Spearman (change) |
|---|---:|---:|---:|
| Apple's published resting HR | 37 | 0.208 | 0.499 |
| NREM mean HR (computed here) | 37 | **0.849** | **0.810** |
| *Correlation between the two* | 37 | *0.192* | — |

They are barely related (ρ = 0.192) and perform completely differently. Apple's resting heart rate is a daily aggregate computed over waking sedentary periods; the NREM value is a sleep-window measurement. **The result is not available from HealthKit today** — it has to be computed from the raw samples.

**Are RMSSD and NREM heart rate redundant?** They correlate at ρ = 0.612 on the Apple side. Substantially coupled, as expected — a longer mean RR interval mechanically permits larger absolute variability — but far from identical, which is consistent with the combination outperforming either alone (0.894 / 0.897 versus 0.849 / 0.810).

That said, the coupling is a genuine interpretive caveat: predicting the Fitbit's *HRV* from Apple's *heart rate* partly exploits the HR–HRV relationship rather than measuring autonomic tone independently. There is a real literature arguing HRV adds little beyond heart rate for this reason. For the practical question — what should an Apple-Watch-only recovery metric be? — that is not disqualifying.

---

## 9. Reproducing this

The analysis library is `recoverylab` — a companion Python project (streaming `lxml` parse of `export.xml`, Parquet intermediates, Streamlit dashboard), not yet published. Every table in this paper is emitted by one script:

```bash
recoverylab ingest ~/Downloads/export.zip     # 2.6 GB XML -> Parquet, once
python analysis/nrem_hr.py                    # regenerates all 12 tables
```

Output lands in `reports/nrem_hr/*.csv`. Numbers in this document are copied from that output, not transcribed from notes.

The comparison depends on having a second instrument in HealthKit. Airlift is what puts it there.

---

## 10. Limitations

- **Single subject, 37 paired nights.** Correlations at this n carry roughly ±0.15–0.2 of uncertainty. Differences smaller than that between adjacent rows should not be read as rankings. The headline gap (0.732 → 0.849, and 0.539 → 0.984 reliability) is comfortably larger than that; the 0.849 vs 0.837 gap between NREM and whole-window heart rate is not.
- **The Fitbit is a reference, not ground truth.** No ECG or PSG was recorded. Its reliability of 0.983 shows it is *consistent*, not that it is *correct*. Everything here measures agreement with a second consumer PPG device.
- **The reference is itself whole-night.** A stage-restricted target scored against a whole-night reference is mildly penalised by construction. §3 controls for this by running the restriction test entirely within the Fitbit's own data, which is why that test exists.
- **Sleep staging is the Apple Watch's own**, and consumer wrist staging misclassifies N3 as core at meaningful rates. The NREM (core+deep) union is used partly because it is robust to exactly that error — a core/deep mislabel does not move a sample out of the zone.
- **Apple chooses when to sample.** If the watch preferentially fires during stillness, its windows are not a random sample of the night, and the thinning ablation in §6 — which draws uniformly — only partly controls for that.
- **The combined index was selected on the same 37 nights it is reported on.** The causal-standardisation row mitigates the standardisation leak but not the selection of the combination rule itself. Treat 0.894 / 0.897 as an upper estimate pending fresh nights.
- **SDNN and RMSSD are different quantities.** All cross-device comparisons are made after a fitted calibration for exactly this reason; raw millisecond agreement between them would be meaningless.

---

## 11. Conclusions

For anyone building a recovery metric on Apple Watch data:

1. **Do not use Apple's published SDNN.** Reliability 0.177, ceiling 0.417. It cannot support night-to-night decisions, and no post-processing changes that.
2. **Do recompute RMSSD from the beat-to-beat intervals** HealthKit already stores. It triples reliability, to 0.539, and is the documented purpose of that field.
3. **Do not chase sleep stages with HRV.** At 3.9 windows a night there is no sample budget for it, and the last-deep-bout target is unreachable by a factor of sixteen.
4. **Do use nocturnal heart rate over core+deep sleep.** It is the single best Apple-side predictor here (0.849 / 0.810), it is not what HealthKit's resting heart rate gives you, and it costs nothing extra to collect.
5. **Combine the two** for 0.894 / 0.897 — but treat that as provisional at n = 37.

And the finding that generalises furthest: on a wrist wearable, **the duty cycle is the design decision that matters**. Heart rate is not a better recovery signal than HRV; it is the same quality of signal, measured seventeen times more often. Apple's HRV feature is limited by a sampling schedule, not a sensor — total daily HRV sampling roughly tripled between watchOS 7 and 27 (3.5 → 9.9 samples/day), yet the overnight count barely moved (3.86 → 4.06 per night). The additional sampling went to waking hours. A watch that spent its existing HRV budget during sleep would not need any of the analysis in this paper.

---

## References

- Apple. *Using Apple Watch to measure heart rate, calorimetry, and activity.* November 2024. [PDF](https://www.apple.com/health/pdf/Heart_Rate_Calorimetry_Activity_on_Apple_Watch_November_2024.pdf)
- Apple Developer Documentation. `heartRateVariabilitySDNN` — introduced iOS 11.0 / watchOS 4.0, September 2017.
- Herzig D, Eser P, Omlin X, Riener R, Wilhelm M, Achermann P. "Reproducibility of Heart Rate Variability Is Parameter and Sleep Stage Dependent." *Front Physiol* 2018;8:1100. doi:[10.3389/fphys.2017.01100](https://doi.org/10.3389/fphys.2017.01100)
- Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology. "Heart rate variability: standards of measurement, physiological interpretation, and clinical use." *Circulation* 1996;93:1043–65.
- Malik M, Farrell T, Cripps T, Camm AJ. "Heart rate variability in relation to prognosis after myocardial infarction: selection of optimal processing techniques." *Eur Heart J* 1989;10:1060–74. (Origin of the 20% artifact-rejection criterion used here.)
- Iber C, Ancoli-Israel S, Chesson A, Quan SF. *The AASM Manual for the Scoring of Sleep and Associated Events.* 2007. (N3 replaces R&K stages 3 and 4.)

> **Independent replication of Herzig et al. (2018).** Their variance decomposition on PSG-staged ECG found the between-night share of overnight SDNN variance to be 3.9%, and a within/between ratio for RMSSD of 3.5. The same decomposition on this export's Apple Watch PPG data gives **3.4%** and **3.7%** respectively — a close match across a different subject, a different sensor modality and a different reference standard. Overnight SDNN sampled in short windows has very little between-night signal to recover *whatever the hardware*. Choosing SDNN, rather than measuring it badly, is the dominant error.
