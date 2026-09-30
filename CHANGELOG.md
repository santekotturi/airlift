# Changelog

All notable changes to Airlift are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Initial public, open-source release (v0.1 — early / pre-GA). Airlift bridges
Fitbit Air (and other Google-account Fitbit devices) data from the Google Health
API into Apple Health, entirely on-device.

### Added

- **Sleep stages** — wake / light / deep / REM mapped to HealthKit, plus an
  `.inBed` sample spanning each session.
- **Seven health metrics** — heart rate, resting heart rate, HRV, SpO₂,
  respiratory rate, steps and distance, each individually toggleable.
- **Review-first sync** — sanity checks against existing Apple Health data, with
  **Automatic** and **Review everything** modes.
- **Idempotent imports** — dedup store keyed on Google dataPoint ID, plus content
  fingerprints that detect and re-stage upstream edits.
- **On-device OAuth** — bring-your-own-client model, PKCE (no secret), refresh
  token stored in the Keychain (this-device-only, never backed up).
- **Incremental, on-demand fetching** with an optional best-effort daily
  `BGAppRefreshTask`.
- **"Sync New Data" Shortcuts action** — an App Intent that runs the full gated
  sync in the background (no UI), so a personal automation (e.g. wake-up alarm
  stopped → open Google Health → wait → sync) can land each night's data in
  Apple Health hands-free. Documented in the README's "Hands-free morning sync".
  When it finishes it posts a notification with last night's HRV — Fitbit's
  average beside the Watch's, or why it was held, or that Google had nothing
  new — switchable per automation ("Notify with HRV summary").
- **Apple Watch native RMSSD (iOS 27).** watchOS 27 on Ultra 4 hardware writes
  its own RMSSD (`heartRateVariabilityRMSSD`, algorithm version 3) about every
  five minutes asleep, ~90 readings a night instead of ~4 spot checks. The
  Recovery and HRV screens read it (read-only permission) and compare it with
  Fitbit's RMSSD like for like: nightly, and window by window with each 5-minute
  Watch reading paired with the Fitbit reading inside it. The continuous v3 SDNN
  the Watch writes alongside is kept out of the "Apple SDNN" series, which stays
  the ~60 s spot check so it means the same thing on every watch.
- **Fitbit HRV is written as RMSSD on iOS 27**, the statistic it always was,
  instead of under SDNN. A one-time **Settings → Fitbit HRV → Move to RMSSD**
  action moves readings already imported: each is copied into RMSSD, the copies
  are confirmed in Apple Health, and only then are the SDNN originals deleted
  (Airlift's own samples only). Airlift's Fitbit HRV is read from both types in
  the meantime, and the sync comparison on iOS 27 sets Fitbit RMSSD beside the
  Watch's RMSSD.
- **Four tabs: Today, Compare, Journal, Sync.** Today leads with last night on
  both devices and a one-line sync status; Compare holds Sleep, HRV and
  Recovery; Journal is the calendar record; Sync is the bridge, review queue
  and history that used to be Home.
- **Sleep comparison screen** — Watch vs Fitbit total sleep and every stage:
  averages, a night-by-night dumbbell chart (one stick per night, no lines
  across nights a device wasn't worn) with per-stage stats, and a single-night
  view with both hypnograms.
- **Per-night tags and notes** — log what you took or did before bed from a
  649-item catalog (supplements, medications, caffeine/alcohol, food timing,
  exercise, light, heat and cold, environment, mind-body, devices, recovery,
  schedule, health) with type-ahead that matches word starts and aliases and
  forgives a typo, or your own tags. Tags attach to the night by its wake day.
  Stored on the phone only (never written to Apple Health); Journal exports a
  CSV with one row per night, both devices' sleep stages, and a column per
  thing logged.
- **Clear queue** on the review queue — sets held items aside without writing
  or tossing anything; fetching those days again brings them back.
- **Google Health detection.** Nights and metric days Google Health's own Apple
  Health sync already wrote are skipped rather than imported a second time
  (sleep matched exactly on `HKExternalUUID`, the Google dataPoint ID), and
  Settings marks each type Google Health already writes.
- Documentation: README setup walkthrough, privacy policy, security policy,
  contributing guide, App Store prep checklist, and a GitHub Pages site.

### Fixed

- **Recovery/HRV screens attribute data to the device that measured it.** "Apple"
  sleep, heart rate and HRV now include only samples an Apple device recorded.
  Previously any non-Airlift sleep counted as Apple's — which, now that Google
  Health writes Fitbit sleep itself, would have merged both hypnograms — and
  "Apple heart rate" included Fitbit heart rate Airlift or Google Health wrote.
  Fitbit sleep and RMSSD written by another app (Google Health) are used as the
  Fitbit side on nights Airlift has none.

- **Sleep review compared Fitbit against itself.** The "Apple Health" side of a
  night summed every non-Airlift sample in a widened window, so Google
  Health's copy of the same Fitbit night was counted as the Watch's and nights
  read as 14–16 h (and every night was held). It is now the Watch's own night
  alone, with naps split off; the Calendar day view had the same bug.
- **Metric comparisons** (heart rate, steps and the rest) counted Google
  Health's Fitbit copies on the Apple side; they now use Apple devices only.
- **Recovery/HRV treated any non-Apple sleep as Fitbit's** — WHOOP or Garmin
  Connect sleep could stand in for it. Only Google Health's writes do now.
- **Tapping the morning reminder crashed Airlift.** The async notification
  delegate completed UIKit's handler off the main thread.

### Changed

- **HRV-only sync by default.** Google Health 5.05 (Aug 2026) now writes sleep,
  heart rate, steps, distance, SpO₂, respiratory rate, resting heart rate and
  more to Apple Health itself — but deliberately omits HRV (Fitbit reports
  RMSSD; Apple Health's only HRV type is SDNN). Airlift therefore now defaults
  to bridging **only HRV**: sleep and the other six metrics are off by default,
  and existing installs are migrated to HRV-only once (everything remains
  re-enableable in Settings → What syncs for people not using Google Health's
  own Apple Health sync).

### Known limitations

- The Google Health API is pre-GA; wire schemas and scopes may shift before its
  September 2026 GA. See *Limitations & known unknowns* in the README.

[Unreleased]: https://github.com/santekotturi/airlift/commits/main
