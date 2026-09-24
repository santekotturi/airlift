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
- **Apple Watch native RMSSD (iOS 27).** watchOS 27 on Ultra 4 hardware writes
  its own RMSSD (`heartRateVariabilityRMSSD`, algorithm version 3) about every
  five minutes asleep, ~90 readings a night instead of ~4 spot checks. The
  Recovery and HRV screens read it (read-only permission) and compare it with
  Fitbit's RMSSD like for like: nightly, and window by window with each 5-minute
  Watch reading paired with the Fitbit reading inside it. The continuous v3 SDNN
  the Watch writes alongside is kept out of the "Apple SDNN" series, which stays
  the ~60 s spot check so it means the same thing on every watch.
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
