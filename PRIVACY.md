# Airlift Privacy Policy

_Last updated: 2026-06-14_

Airlift is a personal, on-device utility that copies your Fitbit sleep and health
data from Google's Health API into Apple Health. **Airlift has no servers and no
account.** This policy explains exactly what the app touches and where it goes.

## The short version

- Airlift runs entirely on your iPhone.
- Your data is **not** sent to the developer or to any Airlift server — there is
  no Airlift server.
- The only network connections Airlift makes are **directly from your phone to
  Google** (to sign in and to read your health data) and to **Apple Health** (on
  your device).
- There is no analytics, no advertising, no tracking, and no third-party SDKs.

## What data Airlift handles, and where it goes

**Google / Fitbit health data.** When you connect your Google account, Airlift
reads your sleep sessions and the health metrics you enable (heart rate, resting
heart rate, heart-rate variability, blood oxygen, respiratory rate, steps, and
distance) directly from Google's Health API. This data is processed on your
device and written into Apple Health. It is never transmitted anywhere else.

**Apple Health (HealthKit) data.** Airlift writes the above data into Apple
Health, and reads your existing Apple Health samples **only** to compare them
against the Fitbit data (so it can avoid duplicates and flag discrepancies).
HealthKit data is never used for advertising or marketing, never sent off your
device by Airlift, and never shared with third parties. Apple Health data is not
stored in iCloud by Airlift.

**Your Google sign-in.** The OAuth refresh token that keeps you signed in is
stored in the iOS **Keychain**, marked device-only (it is excluded from device
backups and transfers). It never leaves your phone except when your phone sends
it to Google to obtain a fresh access token.

**Diagnostic dumps (developers only).** Debug builds built with an explicit
`-AirliftDumps` launch flag may write raw API responses to the app's local
Documents folder to help debug the pre-release Google API. This is off by
default, never enabled in App Store builds, and nothing is uploaded anywhere.

## Bug reports

If you choose to file a bug report from within the app, Airlift opens a
pre-filled **GitHub** issue in your browser for you to review and submit. The
report includes the app version and your device model (e.g. "iPhone16,2") plus
any text you type. **No health data and no sign-in information are included.**
Nothing is sent until you submit the issue yourself on GitHub, which is governed
by [GitHub's privacy policy](https://docs.github.com/site-policy). Filing a bug
report is entirely optional.

## What Airlift does *not* do

- It does not collect, sell, rent, or share your personal data.
- It does not use advertising or analytics SDKs.
- It does not track you across apps or websites.
- It does not create a profile about you.

## Children

Airlift is not directed at children and does not knowingly collect data from
children.

## Your control

You can disconnect your Google account at any time in Settings, which removes the
sign-in from the Keychain. You can remove any data Airlift wrote to Apple Health
from within the app (Calendar → a day → "Remove from Apple Health") or from the
Apple Health app directly. Deleting the app removes its local data and the stored
sign-in.

## Changes

If this policy changes, the updated version will be posted in the app's
repository with a new date above.

## Contact

Questions: **hello@santekotturi.com**, or open an issue at
<https://github.com/santekotturi/airlift/issues>.
