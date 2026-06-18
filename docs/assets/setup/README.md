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

| Filename | Status | What it shows |
|---|---|---|
| `01-enable-api.png` | ✅ have | APIs & Services → Library → the **Google Health API** result. |
| `02-consent-screen.png` | ✅ have | Google Auth Platform → Audience: **External** user type, **Testing** publishing status. |
| `02b-test-users.png` | ✅ have | The **Add users** panel for adding your Google account as a test user. |
| `03-consent-grant.png` | ⬜ still needed | The **on-device** Google consent screen during *Connect Google Health*, showing the three read permissions being granted. This — not the console's Data Access page — is where access is actually given; in Testing mode the Data Access page stays empty. |
| `04a-create-credentials.png` | ✅ have | Credentials → **Create credentials** → OAuth client ID. |
| `04b-app-type.png` | ✅ have | Create OAuth client → choosing the **iOS** application type. |
| `04-ios-client.png` | ✅ have | The iOS OAuth client form — name, bundle ID, Team ID. |

> The captured shots are placeholder/empty forms (no real client IDs, emails, or Team IDs
> visible), so nothing needed redacting. If you re-capture any with real values showing,
> blur them first.

## Xcode

| Filename | Status | What it shows |
|---|---|---|
| `05-config-xcconfig.png` | ✅ have | `Config.xcconfig` open in Xcode with the four keys (placeholder values shown). |
| `06-signing.png` | ⬜ still needed | Target → Signing & Capabilities, showing the Team selected and "Automatically manage signing" on, with the bundle ID matching the OAuth client. |
| `07-run.png` | ⬜ still needed | The scheme/destination bar with your iPhone selected and the Run button — what "build & run" looks like. |

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
