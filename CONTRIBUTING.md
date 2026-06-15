# Contributing to Airlift

Thanks for your interest! Airlift is a small, single-purpose open-source utility. The bar is:
keep it simple, keep it on-device, keep the pure logic tested.

## Getting set up

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. `cp Config.example.xcconfig Config.xcconfig` and fill in your own Google OAuth client
   (see the [README](README.md#setup)). Never commit `Config.xcconfig`.
3. `xcodegen generate && open Airlift.xcodeproj`.

## Project layout

- `Sources/Auth` — OAuth (PKCE), Keychain token store.
- `Sources/GoogleHealth` — API client, **defensive** Codable models, retry/backoff.
- `Sources/Metrics` — the seven quantity metrics: kinds, wire models, HealthKit units.
- `Sources/Health` — pure stage mapping + HealthKit writer.
- `Sources/Sync` — dedup + fingerprint stores, sync-window math, orchestration, sync log.
- `Sources/Background` — `BGAppRefreshTask`.
- `Sources/Views` — SwiftUI screens and components.
- `Sources/Debugging` — opt-in debug dumps, DEBUG-only UI mock fixtures.
- `Sources/Support` — logging, reconnect notifications.
- `Tests` — unit tests for the pure logic.

## Guidelines

- **Test the pure logic.** Anything that doesn't require live HealthKit/network — stage
  mapping, sync-window math, PKCE, civil-time parsing, backoff — should have tests. Run them
  with `Cmd-U` or (substitute any installed iPhone simulator —
  `xcrun simctl list devices available` shows yours):
  ```bash
  xcodegen generate
  xcodebuild test -project Airlift.xcodeproj -scheme Airlift \
    -destination 'platform=iOS Simulator,name=<an installed iPhone simulator>'
  ```
  CI runs the same command on every PR (see `.github/workflows/ci.yml`), picking
  whichever iPhone simulator the runner has installed.
- **Isolate schema changes.** The Google Health wire models live in one file
  (`Sources/GoogleHealth/SleepModels.swift`). When the pre-GA schema shifts, change it there
  and nowhere else — the rest of the app speaks the normalized domain model.
- **No backend, no telemetry.** Airlift is on-device by design. Don't add network calls beyond
  Google OAuth + the Health API.
- **Match the surrounding style.** Doc-comment public types, keep functions small, prefer
  pure functions where the logic allows.
- **Keep credentials out of git.** Anything user-specific belongs in `Config.xcconfig`.

## Reporting issues

If the wire schema doesn't match what your account returns, a redacted sample of the
`dataPoints` JSON (IDs/timestamps scrubbed) is the single most useful thing to attach.
