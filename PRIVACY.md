# Airlift Privacy Policy

_Last updated: 2026-09-29_

Airlift is an iPhone app that copies your Fitbit sleep and health data from the
Google Health API into Apple Health. **Airlift has no servers and no account.**
This policy explains exactly what the app reads, what it keeps, and where your
data goes.

## The short version

- Airlift runs entirely on your iPhone.
- Your data is **not** sent to the developer. There is no Airlift server.
- The app connects **directly from your phone to Google** to sign in and read
  your health data, and writes that data into **Apple Health** on your phone.
- There is no analytics, no advertising, no tracking, and no third-party SDKs.

## Google user data

### What Airlift accesses

When you connect your Google account, Airlift asks Google for three
**read-only** permissions:

| Permission (OAuth scope) | What Airlift reads with it |
|---|---|
| `googlehealth.sleep.readonly` | Sleep sessions and sleep stages (awake, light, deep, REM) |
| `googlehealth.health_metrics_and_measurements.readonly` | Heart rate, resting heart rate, heart-rate variability, blood oxygen, respiratory rate |
| `googlehealth.activity_and_fitness.readonly` | Steps and distance |

Airlift cannot write, change, or delete anything in your Google account. It
does not request your name, email address, contacts, location, or any other
Google data.

### How Airlift uses it

Airlift uses this data for one purpose: to write it into Apple Health on your
iPhone, and to show it to you in the app so you can compare it with what is
already in Apple Health before it is saved. You choose which data types sync in
Settings. Data is never used for advertising, never sold, and never used for
any purpose other than this one.

No person reads your data. The developer has no way to see it, because it never
leaves your phone.

### Who it is shared with

Airlift shares your Google health data with exactly one party: **Apple
Health**, on your own iPhone, at your direction. Apple Health is governed by
[Apple's privacy policy](https://www.apple.com/legal/privacy/). Airlift does not
share, sell, or transfer Google user data to anyone else.

### Limited Use

Airlift's use of information received from the Google Health API adheres to the
[Google Health API Developer and User Data Policy](https://developers.google.com/health/policies/health-api-developer-user-data-policy),
including the Limited Use requirements. Airlift's use and transfer of
information received from Google APIs also adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Apple Health (HealthKit) data

Airlift writes the data above into Apple Health. It also reads your existing
Apple Health samples of the same types **only** to compare them with the Fitbit
data, so it can avoid duplicates and flag discrepancies before writing.
HealthKit data is never used for advertising or marketing, never sent off your
device by Airlift, never shared with third parties, and never stored in iCloud
by Airlift.

## What Airlift stores on your iPhone

Airlift does not keep its own copy of your health readings. Once data is in
Apple Health, Apple Health is where it lives. On your iPhone, Airlift keeps
only:

- **Your Google sign-in token**, in the iOS Keychain, marked device-only. It is
  excluded from backups and device transfers, and is only ever sent to Google to
  get a fresh access token.
- **Sync bookkeeping**: the IDs of Google data points already written or
  discarded, so nothing is written twice; which days have synced; and your
  settings.
- **A short activity log** of recent syncs, which can include summaries such as
  a night's total sleep time. It is capped at the most recent entries.

All of this stays in the app's private storage on your iPhone and is never
uploaded.

**Diagnostic dumps (developers only).** Debug builds launched with an explicit
`-AirliftDumps` flag can save raw API responses to the app's local Documents
folder for debugging. This is off by default, impossible to enable in App Store
builds, and nothing is uploaded anywhere.

## How Airlift protects your data

- All connections to Google use HTTPS. Airlift makes no exceptions to Apple's
  App Transport Security.
- The sign-in token lives in the iOS Keychain, locked to this device, rather
  than in ordinary app storage.
- With no server, there is no remote database that could be breached.
- The source code is public at
  <https://github.com/santekotturi/airlift>, so anyone can check these claims.

## Managing and deleting your data

- **Stop syncing a data type:** turn it off in Settings → *What syncs*.
- **Disconnect Google:** Settings → Disconnect removes the sign-in token from
  your iPhone and revokes Airlift's access at Google. If your phone is offline
  at that moment, the app tells you, and you can remove Airlift at
  <https://myaccount.google.com/connections>. You can also revoke access there
  at any time without opening Airlift.
- **Remove data Airlift wrote to Apple Health:** in Airlift, open Calendar →
  a day → *Remove from Apple Health*, or delete it in the Health app.
- **Delete everything Airlift stores:** delete the app. iOS removes its sign-in
  token, bookkeeping, and activity log. Data already written to Apple Health
  stays there until you remove it, because it is now yours in Apple Health.

Airlift has no account, so there is no account to deactivate or delete, and the
developer holds no copy of your data to delete.

## Bug reports

If you choose to report a bug from inside the app, Airlift opens a pre-filled
**GitHub** issue in your browser for you to review and submit. It includes the
app version and your device model, such as "iPhone16,2", plus any text you type.
**No health data and no sign-in information are included.** Nothing is sent
until you submit the issue yourself on GitHub, which is governed by
[GitHub's privacy policy](https://docs.github.com/site-policy). Filing a bug
report is optional.

## What Airlift does *not* do

- It does not collect, sell, rent, or share your personal data.
- It does not use advertising or analytics SDKs.
- It does not track you across apps or websites.
- It does not build a profile about you.

## Children

Airlift is not directed at children and does not knowingly collect data from
children.

## Changes

If this policy changes, the updated version is posted here and in the app's
repository with a new date at the top. If Airlift ever starts using data in a
new way, the app will ask for your consent first.

## Contact

Questions: **airlift@santekotturi.com**, or open an issue at
<https://github.com/santekotturi/airlift/issues>.
