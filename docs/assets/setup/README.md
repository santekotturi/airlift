# Setup screenshots

These images are referenced from the **Setup** section of the main
[README](../../../README.md). They can't be generated — they're screenshots of
*your* Google Cloud Console and Xcode, so capture them once and drop them in here
with the exact filenames below. Until they exist, the README shows a short
"screenshot to add" note in their place.

Capture on a clean/blank project where possible, and **redact** any real client
IDs, project numbers, and your email before committing (a quick blur or black box
is fine — these end up in a public repo).

## Google Cloud Console

| Filename | What to capture |
|---|---|
| `01-enable-api.png` | APIs & Services → Library → "Google Health API" page, with the **Enable** button visible. |
| `02-consent-screen.png` | OAuth consent screen set to **External** + publishing status **Testing**, with your Google account added under **Test users**. |
| `03-scopes.png` | The Scopes step showing the three `googlehealth.*` **read-only** scopes selected (sleep, health metrics & measurements, activity & fitness) — and nothing else. |
| `04-ios-client.png` | Credentials → the **iOS OAuth client** showing the Client ID and the registered bundle ID (**redact the digits** of the client ID). |

## Xcode

| Filename | What to capture |
|---|---|
| `05-config-xcconfig.png` | `Config.xcconfig` open in Xcode with the four keys filled in (`AIRLIFT_BUNDLE_ID`, `GH_CLIENT_ID`, `GH_REVERSED_CLIENT_ID`, `DEVELOPMENT_TEAM`) — **redact** the real values. |
| `06-signing.png` | Target → Signing & Capabilities, showing the Team selected and "Automatically manage signing" on, with the bundle ID matching the OAuth client. |
| `07-run.png` | The scheme/destination bar with your iPhone selected and the Run button — what "build & run" looks like. |

## Recommended format

- **PNG**, retina is fine; crop to the relevant panel rather than the whole screen.
- Keep them reasonably small (under ~1 MB each) so the repo stays light. These
  live under `docs/assets/setup/` and **are** committed (only the generated
  marketing PNGs in `docs/screenshots/` are gitignored).

Once a screenshot exists, replace its `> _📸 Screenshot to add: …_` note in the
README with a real image tag, e.g.:

```markdown
<img src="docs/assets/setup/01-enable-api.png" width="80%" alt="Enabling the Google Health API" />
```
