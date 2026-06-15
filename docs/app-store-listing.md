# App Store listing copy

Ready-to-paste metadata for App Store Connect. Character limits noted in
brackets — current text is within them.

## Name [30]

```
Airlift: Fitbit to Apple Health
```

(If "Airlift" alone is available as a name, prefer it and move the descriptor to
the subtitle.)

## Subtitle [30]

```
Sleep & health, on your device
```

## Promotional text [170]

```
Bring last night's Fitbit sleep — with full stages — plus heart rate, HRV, SpO2,
steps and more into Apple Health. Runs entirely on your iPhone. No account, no
server.
```

## Keywords [100, comma-separated, no spaces]

```
fitbit,sleep,apple health,healthkit,sync,heart rate,hrv,spo2,steps,bridge,import,health,fitness
```

## Description [4000]

```
Airlift carries your Fitbit sleep and health data into Apple Health — so
everything you track lives in one place, on your iPhone.

The Fitbit Air and other Google-account Fitbit devices keep your data in Google's
health ecosystem, which doesn't write to Apple Health on its own. Airlift bridges
the gap: every morning it pulls last night's sleep and your latest metrics from
Google's Health API and writes them into Apple Health with full detail.

WHAT CROSSES OVER
• Sleep with full stages — awake, light, deep, and REM
• Time in bed
• Heart rate and resting heart rate
• Heart-rate variability (HRV)
• Blood oxygen (SpO2) and respiratory rate
• Steps and distance

CHECKED BEFORE IT LANDS
Airlift compares every reading against what Apple Health already has and runs it
through sanity checks. Choose how much oversight you want:
• Automatic — clean data lands on its own; anything unusual waits for you
• Review everything — nothing is written without your OK
You can remove anything Airlift wrote, any time.

PRIVATE BY DESIGN
Airlift runs entirely on your iPhone. There is no Airlift account and no Airlift
server. Your Google sign-in stays in the device Keychain and never leaves your
phone. No analytics, no advertising, no tracking.

TRAVEL-CORRECT
Sleep is recorded with its own time zone, so a night logged in one city lands on
the right day no matter where you sync.

Airlift is open source. Every line is public, and you can report bugs right from
the app.
```

## Support URL

```
https://github.com/santekotturi/airlift
```

## Marketing URL (optional)

```
https://github.com/santekotturi/airlift
```

## Privacy Policy URL

```
https://github.com/santekotturi/airlift/blob/main/PRIVACY.md
```

(Better: enable GitHub Pages and host a rendered page, e.g.
`https://santekotturi.github.io/airlift/privacy`.)

## Category

- Primary: **Health & Fitness**
- Secondary: (optional) Utilities

## "What's New" (for v0.1.0)

```
First release. Bridges Fitbit sleep (with stages) and health metrics into Apple
Health, on-device. Review or auto-import, with sanity checks against your
existing Health data.
```

## App Review notes (critical — read by the reviewer)

```
Airlift writes Fitbit-sourced health data into Apple HealthKit. It reads existing
HealthKit samples only to avoid duplicates and flag discrepancies; HealthKit data
is never sent off device and never used for advertising.

To test, the reviewer needs a Google account that has Fitbit sleep data and is
authorized on the app's OAuth client. Demo account + steps:
  1. <demo Google account email / password OR note that one will be provided>
  2. Launch the app, tap "Connect Google Health", complete Google sign-in.
  3. Tap "Fetch now". Approve the HealthKit write prompt.
  4. Open Apple Health > Browse > Sleep to see the imported night.

Background Modes (fetch) is used for an optional once-daily refresh.
```

> ⚠️ The demo-account step depends on a **verified production OAuth client** — see
> `app-store-checklist.md`. Without it, the reviewer cannot complete sign-in.
