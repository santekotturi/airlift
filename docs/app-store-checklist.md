# App Store submission checklist

Status of everything needed to ship Airlift on the App Store. Grouped by who
owns it. **Read the blocker first — it gates the actual upload.**

---

## 🚫 Blocker — production OAuth client (do this first)

The App Store ships one pre-compiled binary, so it must embed **one shared Google
OAuth client** (the open-source build is bring-your-own-client via
`Config.xcconfig`, which an App Store user can't fill in). That shared client
needs, from Google:

- [ ] A **published** (not "Testing") OAuth client in a Google Cloud project.
- [ ] **Restricted-scope verification** for the `googlehealth.*` scopes — a CASA
      security assessment (often paid, multi-week), a privacy policy on a
      **verified domain**, a homepage on that domain, scope justifications, and a
      demo video.
- [ ] Confirmation the **Google Health API is available for production** use — it
      is pre-GA ("built in public"); access may be allowlisted until GA
      (targeted ~Sept 2026).

Until this is done, real users and the **App Store reviewer** cannot complete
sign-in (unverified-app screen; Testing-mode tokens expire weekly and cap at 100
users). Everything below can be prepared in parallel, but nothing submits without
this.

When ready, set the production client ID/reversed ID and a fixed bundle ID in the
release `Config.xcconfig` (kept out of git).

---

## You set up (Apple side)

- [ ] **Apple Developer Program** membership ($99/yr).
- [ ] Register a **fixed bundle ID** (e.g. `com.santekotturi.airlift`) in the
      Developer portal with the **HealthKit** capability enabled. (Today the
      project uses `$(AIRLIFT_BUNDLE_ID)` from local config.)
- [ ] Create the app record in **App Store Connect**.
- [ ] **Distribution signing**: automatic signing in Xcode with your team, or an
      App Store provisioning profile.

## App Store Connect fields

- [ ] **Privacy Policy URL** — required for HealthKit apps. Use
      `https://github.com/santekotturi/airlift/blob/main/PRIVACY.md` or a GitHub
      Pages URL.
- [ ] **Support URL** — the GitHub repo.
- [ ] **App Privacy ("nutrition labels")** — suggested answers:
  - Health & Fitness data: the app **reads/writes HealthKit on-device only** and
    does **not** send it to the developer → for data the developer collects,
    answer **"Data Not Collected"** for health data.
  - Diagnostics: the in-app bug report sends **app version + device model + your
    typed text to GitHub** (a third party) only when you submit. If you want to
    be conservative, declare **Diagnostics → not linked to identity, not used for
    tracking**. (Health data is never included.)
  - No tracking, no ads, no analytics SDKs.
- [ ] **Category**: Health & Fitness (set in code via `LSApplicationCategoryType`;
      also select it here).
- [ ] **Age rating** questionnaire (no objectionable content → 4+).
- [ ] **Pricing**: Free.
- [ ] **Export compliance**: already declared via
      `ITSAppUsesNonExemptEncryption=false` (HTTPS/Apple crypto only).
- [ ] **App Review notes** + **demo account** — see `app-store-listing.md`. The
      reviewer needs a working Google account on the verified client.
- [ ] **Screenshots** — see below.
- [ ] Listing text — see `app-store-listing.md`.

## Assets

- [x] **App icon** — present (light/dark/tinted care-package) in
      `Assets.xcassets/AppIcon`.
- [ ] **Screenshots** — required for **6.9"** (iPhone 16 Pro Max, 1320×2868) and
      recommended for 6.5". Generate with:
      `Scripts/screenshots.sh` (captures the mock screens on a Pro Max simulator
      with a clean 9:41 status bar). Drafts land in `docs/screenshots/`.
- [ ] (Optional) App Preview video.

## Code / build

- [x] HealthKit usage strings present and accurate.
- [x] Background mode limited to `fetch`.
- [x] Debug-only code (dumps, UI mock, raw-JSON viewer) compiled out of release.
- [x] No ATS exceptions; HTTPS only.
- [ ] Bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` per release (currently
      0.1.0 / 1).
- [ ] Archive a **Release** build (`xcodebuild archive`) and validate in the
      Organizer before uploading.

## Privacy policy hosting (nice-to-have)

- [ ] Enable **GitHub Pages** for a rendered policy page instead of the raw
      markdown URL.

---

### Recommended path

Ship the **open-source / sideload** build now (it's ready). Pursue the Google
verification + Health API GA as a separate track; the moment the production
client exists, the Apple-side items above are a day or two of work since the
copy, policy, screenshots, and code are already prepared.
