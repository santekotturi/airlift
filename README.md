# Airlift

**Your sleep, airlifted to Apple Health every morning. Bridges Fitbit Air (and other Google-account Fitbit devices) sleep data into Apple Health — on-device, open source, no server.**

> Formerly *AirKit*. The Xcode project, scheme, and bundle ID keep the `AirKit` name; everything user-facing says **Airlift**.

The Fitbit Air is a screenless, sleep-focused tracker whose data lives in Google's
health ecosystem and does **not** export to Apple Health natively. Airlift is a small
iOS app that pulls last night's sleep session from the **Google Health API** and writes
it into HealthKit as `sleepAnalysis` samples with full stage detail (wake / light / deep
/ REM).

It runs entirely on your device. Your Google refresh token never leaves your phone —
there is no backend, unlike most of the commercial Fitbit↔Health sync apps.

> **Status:** early / v0.1. The Google Health API is pre-GA ("built in public"); its
> schemas and scopes may shift before its September 2026 GA. The wire models here are
> defensive but expect to verify them against a real payload (see [Limitations](#limitations)).

---

## Features

- 🛌 **Full sleep stages** — wake → `.awake`, light → `.asleepCore`, deep → `.asleepDeep`,
  REM → `.asleepREM`, mapped faithfully to HealthKit.
- 🛏 **Time in bed** — also writes one `.inBed` sample spanning each session.
- 💓 **All read-only scopes up front** — sleep is what v1 syncs, but the app requests every
  read-only Google Health scope (health metrics, activity & fitness, location, nutrition) so
  future data types need no re-consent. No write scope is ever requested.
- 🔁 **Idempotent** — a dedup store keyed on the Google dataPoint ID means re-running never
  creates duplicate Health samples; edited sessions are deleted and rewritten.
- 🔒 **On-device & private** — OAuth (PKCE) + refresh token live in the Keychain. No server.
- ⏰ **Automatic** — a daily `BGAppRefreshTask`, plus on-launch sync and a manual **Sync now**
  button as the real guarantee.
- 🌍 **Travel-correct** — sessions are resolved with their own UTC offset, not the phone's
  current time zone.

## Why this exists

Google has said native Google Health → Apple Health write-back is "coming later in 2026,"
but it isn't shipped, has no date, and aggregated sleep-stage fidelity has historically
been hit-or-miss. Airlift gives you faithful stages **now**, with full local control. Treat
it as a bridge until (and if) native sync makes it redundant.

---

## Requirements

- An iPhone (iOS 17+) and a Mac with **Xcode 16+**.
- A Fitbit Air or other Google-account Fitbit device that reports sleep.
- A Google account with Fitbit data, and your own **Google Cloud project** (free).
- [XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`) — the Xcode
  project is generated, not committed.
- An Apple Developer account to install on a real device (the Simulator can't run HealthKit
  writes against real data, but the app builds and the unit tests run there).

## Setup

### 1. Create your Google OAuth client

1. In the [Google Cloud Console](https://console.cloud.google.com/), create (or reuse) a
   project and **enable the Google Health API**.
2. Configure the **OAuth consent screen** as **External / Testing** and add your personal
   Google account (the one your Fitbit is on) under **Test users**. See
   [OAuth & consent](#oauth--consent-read-this-before-you-start) below for why.
3. Create an **iOS OAuth client ID** with the bundle ID `com.santekotturi.airkit` (or change
   the bundle ID in `project.yml` to your own and use that). iOS clients are public clients —
   **no client secret**; Airlift uses PKCE.
4. On the consent screen's **Scopes** step, add all five read-only Google Health scopes
   (`googlehealth.sleep.readonly`, `…health_metrics_and_measurements.readonly`,
   `…activity_and_fitness.readonly`, `…location.readonly`, `…nutrition.readonly`).
   Do **not** add any `.writeonly` scope — Airlift never writes back to Google.

### 2. Configure the build

```bash
git clone <your-fork-url> AirKit
cd AirKit
cp Config.example.xcconfig Config.xcconfig
```

Edit `Config.xcconfig` and fill in:

| Key | Value |
|---|---|
| `GH_CLIENT_ID` | `1234567890-abc.apps.googleusercontent.com` |
| `GH_REVERSED_CLIENT_ID` | `com.googleusercontent.apps.1234567890-abc` |
| `DEVELOPMENT_TEAM` | your 10-char Apple Team ID (blank = Simulator only) |

`Config.xcconfig` is gitignored — your credentials never get committed. (They aren't secrets
— public iOS clients have no secret — but each user brings their own client.)

### 3. Generate & build

```bash
xcodegen generate
open AirKit.xcodeproj
```

Build & run on your device, tap **Connect Google Health**, grant the consent screen and the
HealthKit prompt, then **Sync now**. Open Apple Health → Browse → Sleep to verify.

---

## OAuth & consent (read this before you start)

Airlift uses a **bring-your-own-client** model: there is **no shared OAuth client** baked into
the app. Each user registers their own OAuth client in their own Google Cloud project and
drops the client ID into `Config.xcconfig`. This is deliberate — it keeps the repo
credential-free, avoids anyone depending on a single client the maintainer has to keep alive,
and (most importantly) sidesteps Google's **Restricted-scope verification**, which the
`googlehealth.*` health scopes would otherwise require. (Verification is a heavyweight,
often paid security assessment aimed at published hosted apps — not a fit for a sideloaded
personal utility.)

**Use External + Testing, with a personal Google account:**

- The account you authorize with must be the one your **Fitbit data lives on**. As of 2026,
  Google does **not** allow Google Workspace accounts to access health/Fitbit data, so this is
  effectively always a **personal `@gmail.com` account** — even if you have a Workspace org.
- That rules out the *Internal* consent type (Internal is org-only and can't touch personal
  health data anyway). So: consent screen = **External**, publishing status = **Testing**, and
  add your own Google account under **Test users**.
- In Testing mode the **refresh token expires every ~7 days**, so you'll re-tap **Connect**
  about once a week. Airlift detects the expired/revoked state and shows a "Reconnect needed"
  status rather than crashing.

> ⚠️ Confirm two things first (M0): that the **Google Health API is actually enabled and
> accessible** to your project (it's pre-GA and may be allowlisted), and that your **personal
> account in Testing mode** can consent to these specific health scopes. Google sometimes gates
> health scopes harder than other Restricted ones.

> 💡 **Want a one-tap experience for the whole community instead of BYO?** That would mean
> publishing *one* verified client (Model A) — Google Restricted-scope verification, a privacy
> policy, a verified domain, and ongoing responsibility for all users' data. Out of scope for
> v0.x, but noted as a possible future if the project takes off.

---

## Architecture

```
iOS app (SwiftUI, on-device only)
 ├─ Auth/          PKCE + ASWebAuthenticationSession OAuth, Keychain token store
 ├─ GoogleHealth/  sleep dataPoints client, defensive Codable models, retry/backoff
 ├─ Health/        stage mapper (pure) + HealthKit writer (per-stage + .inBed)
 ├─ Sync/          dedup store, sync-window logic, SyncEngine orchestration
 └─ Background/    BGAppRefreshTask scheduler
```

Sync cycle: ensure a valid access token → `GET sleep dataPoints` for the window (re-pulling
the last ~2 days to catch late/edited sessions) → skip IDs already in the dedup store → map
stages → write to HealthKit → record IDs → advance the high-water mark. The window is never
advanced past a failed fetch.

## Limitations & known unknowns

- **Wire schema is provisional.** `Sources/GoogleHealth/SleepModels.swift` is a best-effort
  shape for the pre-GA API. Capture a real `dataPoints` response and adjust the `CodingKeys`
  / field names — they are isolated to that one file on purpose.
- **Background timing is best-effort.** iOS may not fire `BGAppRefreshTask` daily; on-launch
  and manual sync are the real guarantees.
- **Google may make this obsolete.** Native Google Health → Apple Health write-back is
  promised for "later in 2026." If it ships and gives you faithful stages, you may not need this.

## Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The pure logic (stage mapping, sync
window, PKCE, civil-time parsing, backoff) is unit-tested; please keep it that way.

## License

[MIT](LICENSE) © 2026 Sante Kotturi
