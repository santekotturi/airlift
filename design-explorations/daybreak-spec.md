# Airlift "Daybreak Bridge" — iOS implementation spec

The approved direction is `design-explorations/c-daybreak.html` (screenshot: `design-explorations/preview-c.png` — **Read this image before designing any screen**). This spec adapts it to SwiftUI for the existing Airlift app and adds two user-selectable sync modes.

## Hard constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, iOS 17 deployment target, SwiftUI + Swift Charts. The project is generated with XcodeGen — **after adding/removing files run `xcodegen generate`** (all files under `Sources/` are auto-included).
- Build: `xcodebuild -project Airlift.xcodeproj -scheme Airlift -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/airlift-dd build`
- Tests: same command with `test` (runs the existing unit tests; keep them green).
- Simulator UDID for iPhone 17 Pro: `F4FDCBC1-32C5-4087-97FE-30119A1773F3`. App bundle id: `com.santekotturi.airlift`. Built app: `/tmp/airlift-dd/Build/Products/Debug-iphonesimulator/Airlift.app`.
- Launch with mock data: `xcrun simctl launch booted com.santekotturi.airlift -AirliftUIMock 1 -AirliftUIMockScreen home` (screen ∈ `home | session | metric | history | settings`). Screenshot: `xcrun simctl io booted screenshot <path>.png`.
- Do not break the existing engine contract: review-first staging, dedup, toss persistence. Do not touch `Sources/Auth`, `Sources/GoogleHealth`, `Sources/Background` except where this spec says.

## Style tokens (define once in `Sources/Views/Theme/Daybreak.swift`)

```
enum Daybreak {
  // colors (Color(red:green:blue:) from hex)
  skyTop      #FDF3E7   skyMid    #F7E3E0   skyLow   #E8E6F7   // bg gradient top→bottom
  card        #FFFFFF
  ink         #2A2440   // primary text
  mid         #75708C   // secondary text
  faint       #AAA6BD   // tertiary / section labels
  line        #ECE9F4   // hairline separators
  sun         #FF9D5C   sunDeep   #F4753A                      // CTA gradient
  plum        #6C5CE0   // links/secondary actions; chip "new" bg #EDE9FF
  ok          #2FA56F   // chip bg #E3F5EC
  warn        #D98A1C   // chip bg #FBF0DC
  fail        #D9512C   // chip bg #FBE3DC
  // sleep stage colors (shared scale, both Google + Apple lanes)
  awake #FFB066   rem #A88CF5   core #5FC6D8   deep #5F74E8   inBed gray.opacity(0.45)
}
```

- **Typography**: SF Rounded everywhere. Big titles `.system(size: 30, weight: .bold, design: .rounded)`; big numbers `.system(size: 40–46, weight: .heavy, design: .rounded)` with sunDeep emphasis spans; body `.system(.subheadline, design: .rounded)`; section labels: 11.5pt semibold uppercase, tracking ~1.6, color faint.
- **Background**: full-screen `LinearGradient(skyTop → skyMid → skyLow, top→bottom)` `.ignoresSafeArea()` behind a `ScrollView`. Hide default nav-bar background (`.toolbarBackground(.hidden)`), keep custom in-content headers.
- **Cards**: white, `RoundedRectangle(cornerRadius: 26, style: .continuous)`, shadow `color: plum.opacity(0.16), radius: 15, y: 10`, padding 18–20. Define a `.daybreakCard()` view modifier.
- **Primary button**: full-width, 17pt bold rounded white text, `LinearGradient(sun → sunDeep, topLeading→bottomTrailing)`, corner radius 20, shadow sunDeep.opacity(0.45) radius 14 y 8.
- **Ghost button**: plum text semibold on `plum.opacity(0.08)`, radius 20.
- **Chips**: capsule, 11.5pt bold, tinted bg per status (ok/warn/new above).
- **Copy voice**: plain language, warm, no jargon. "Adds up cleanly", "Nothing is written until you approve it", "You skipped Sunday night — nothing was written". Sentence case everywhere.

## Reusable components (`Sources/Views/Components/DaybreakComponents.swift`, created in scaffold)

- `StageStrip(segments: [(color: Color, fraction: Double)], height: CGFloat)` — horizontal proportional colored strip, clipped to radius 5. Build adapters from `[SleepStageSegment]` and `[AppleSleepSegment]` over a shared time domain (union of both), mapping stages to the shared color scale (reuse the `LaneStage` normalization idea from the old `SessionCompareView`).
- `BridgeView` — the signature element: "G" endpoint (white rounded square, blue serif-ish G) and Apple Health endpoint (pink/red gradient rounded square with ♥), connected by a dotted quad-bezier arc with 3 small sunDeep dots animating along it (use `TimelineView(.animation)` + a function point-on-quad-bezier(t); stagger t by 1/3; ~2.6 s loop). Caption labels "Fitbit Air" / "Apple Health" under endpoints.
- `AgreementMeter(percent: Double)` — capsule track `#F3F0FB`, green gradient fill, caption like "92% — the two trackers tell the same story" (ok color, bold).
- `CheckCard(result: CheckResult)` — friendly row: circular icon (✓ green tint / ! amber / ✕ red tint), bold plain-language title, secondary detail.
- `MiniStat(emojiOrIcon, value, caption)` — small white card for 2×2 grids.
- `HeadsUpCard` — the pre-GA note: warm gradient card (`#FFF8EC → #FDEEDE`), glowing sun circle (radial gradient `#FFD29A → sunDeep`), 12.5pt text in `#7C5A33` with `#B3622A` bold lead. Copy: "**Heads up:** Google's Health API is still pre-release. Until it's final (Sept 2026), fields can change — that's exactly why Airlift shows you every night before it lands in Apple Health." (In Automatic mode the last clause reads "— anything unusual is held for your review.")
- `DayBadge(date: Date)` — 46×46 rounded square, lavender gradient, big day number + tiny weekday.

## New behavior: sync modes (user preference)

`enum SyncMode: String, CaseIterable { case automatic, reviewEverything }`, stored via `@AppStorage("airlift.syncMode")` (raw string), **default `.automatic`**.

- **Automatic (default)**: after `fetchForReview` stages data, the engine auto-imports every staged session/metric batch whose checks contain **no `.warn` and no `.fail`** (pass/info only). Items with warnings or failures stay in the review queue, labeled "held back by checks". Implement as `func autoImportClean() async` on `SyncEngine`, called from the app-launch task and after manual fetches **only when mode == .automatic** (the engine can read the mode from UserDefaults via a small injected closure or a stored property set by the app — keep the engine testable).
- **Review everything**: today's behavior, nothing imported without a tap.
- Settings UI: a picker/two option cards with checkmark on the active mode. Automatic card copy: "Clean nights land in Apple Health on their own. Anything that fails a check waits for you." Review card copy: "Every night and metric waits for your OK before it's written."
- Home copy adapts: Automatic → headline like "2 nights landed automatically · 1 held for review"; Review → "1 night + 427 points waiting for your OK".

## New feature: sync history ("What crossed over")

- `Sources/Sync/SyncLog.swift`: `struct SyncLogEntry: Codable, Identifiable, Equatable { let id: UUID; let date: Date; let kind: Kind; let title: String; let detail: String }` with `enum Kind: String, Codable { case fetched, imported, autoImported, tossed, held, nothingNew, connected, error }`.
- `@MainActor @Observable final class SyncLogStore`: `private(set) var entries: [SyncLogEntry]` persisted as JSON in UserDefaults (key `airlift.syncLog`), newest first, capped at 200. `func record(_ kind:, title:, detail:)`.
- `SyncEngine` takes a `SyncLogStore` (new init param, wired in `AppModel`) and records: fetch completed (counts + window), nothing new, imported (per item, with plain-language summary), auto-imported, tossed, held-by-checks, reconnect needed/connected, errors.
- `HistoryView` renders: 2×2 `MiniStat` grid (nights bridged, held back by checks, duplicates blocked — derivable from dedup/tossed store counts or log, bytes off-device "0"), then a vertical timeline (dot + line, dots colored by kind: imported=sunDeep/ok, fetch=plum, tossed=warn) with plain-sentence entries grouped newest-first ("Today · 6:45 AM — Last night landed in Apple Health — 7 h 24 m, 15 stage samples…").

## Mock mode (DEBUG only)

- Trigger: launch argument `-AirliftUIMock 1` (read `UserDefaults.standard.bool(forKey: "AirliftUIMock")`).
- `Sources/Debugging/UIMock.swift` builds fixtures **relative to `Date()`** so "last night" is always last night:
  - Session A (last night): 23:38 → 07:02, ~15 stage segments matching a realistic hypnogram (deep early, REM late, two brief wakes); Apple segments overlapping but offset a few minutes with slightly different stage splits; HR samples every 5 min, 47–112 bpm, dipping overnight. Checks: produce by calling the real `SanityChecks.run(google:appleSleep:heartRate:)`.
  - Session B (3 nights ago): 21:55 → 09:07 (11.2 h) so the real checks yield a duration **warn** → demonstrates "held back by checks".
  - Metric batches for last night/yesterday: heartRate (~100 downsampled pts, avg 58), hrv (8 pts ~42 ms), oxygenSaturation (7 pts ~96.4 %, min 93), respiratoryRate (1 pt 14.2), steps (hourly, total ~8 400 with Apple total ~8 100 and hourly apple series) — call real `SanityChecks.runMetric` for checks where signatures allow, else construct sensible `CheckResult`s.
  - ~10 `SyncLogEntry`s over the past 5 days telling the story from the mock (fetches, imports incl. auto, one toss "Google reported 11.2 h…", one nothing-new, one reconnect).
- `SyncEngine` gets a DEBUG-only method (declared **inside SyncEngine.swift** — `private(set)` setters are file-scoped) `func applyUIMock(staged:stagedMetrics:status:isConnected:)`, plus an `isUIMock` flag. When `isUIMock`: `importStaged`/`importMetricBatch` skip `writer`/HealthKit and dedup writes and just retire the item + log; `fetchForReview` plays a canned pipeline animation (~0.4 s per data type via `Task.sleep`, walking waiting→fetching→comparing→done) then restores the seeded staged items; `connect`/`disconnect` just flip state. No HealthKit authorization prompt may ever appear in mock mode.
- `AppModel`/`AirliftApp`: when mock is active, force `isConfigured` semantics to true (bypass the setup-hint path), seed engine + log store, and **skip** the real on-launch `fetchForReview`.
- Screen selector: `-AirliftUIMockScreen <name>` → `UserDefaults.standard.string(forKey: "AirliftUIMockScreen")`. `ContentView` (mock only) pre-populates its `NavigationStack` path on first appear: `session` → SessionCompareView for the **held** session B (shows warn states; it's the richer screen), `metric` → MetricCompareView for the heart-rate batch, `history` → HistoryView, `settings` → SettingsView, `home`/absent → root.

## Screen specs (match preview-c.png composition; adapt, don't transliterate)

### Shell — `ContentView.swift`
NavigationStack over `HomeView`, gradient background applied at the shell so pushed screens share it, typed `navigationDestination`s for `StagedSession`, `StagedMetricBatch`, `HistoryRoute`, `SettingsRoute`. Toolbar: top-right gear (Settings), top-left small "Airlift" wordmark or nothing. System nav bar background hidden; pushed screens get a plain back chevron.

### Home — `HomeView.swift`
Top→bottom: greeting header ("Good morning ☀️" / afternoon / evening by hour + subline "Last night came over the bridge at 6:42 AM" from the log); bridge card (BridgeView, big-number banner like "**1 night** + 427 points" with sunDeep emphasis, subline per mode, primary CTA "Review last night →" or, when queue is empty in automatic mode, "Fetch now"; ghost "Fetch again · last 7 days" with the existing 7/14/30-day menu); "Ready for review" section listing staged sessions (DayBadge, "7 h 24 m sleep", chip ✓ checks pass / ! held back, time range + agreement %, StageStrip) and metric batches ("Overnight vitals" grouped row or per-kind rows with chip "new to Apple"); "Recent crossings" section — last 3 log entries as rows with a "See all" → History; HeadsUpCard at the bottom. While syncing: replace bridge banner with the live pipeline (reuse `engine.pipeline`, friendly icons, animated). Also handle: not connected (bridge card becomes "Connect Google Health" CTA + explainer), reconnect needed (warm amber card "Your weekly Google sign-in expired — reconnect to keep the bridge open"), not configured (setup hint card, keep existing copy), fetch failed (apologetic card with detail + retry).

### Session review — `SessionCompareView.swift` (restyle, keep all data/logic)
Header: "Last night, side by side" (or weekday for older), subline "Fitbit Air's reading vs. what's already in Apple Health." Card 1: labeled StageStrips — "FITBIT AIR · 7 h 24 m" + chip "importing"/"held", below "APPLE WATCH · 7 h 13 m · already in Health" (omit Apple lane gracefully with "No Apple data for this night" if empty); shared stage legend (colored dots); AgreementMeter (compute overlap agreement between the two lanes — add a small pure helper, e.g. fraction of overlapping minutes where normalized stages match; if no Apple data show "nothing to compare against" state). Keep the existing Swift Charts hypnogram as a secondary "Detail" card (restyled axis/colors to theme) and the overnight heart-rate chart card if data exists. 2×2 MiniStat grid (Deep, REM with Δ vs Apple when available; SpO₂/resting HR from staged HR if present, else asleep total + efficiency). "Before it lands" card: CheckCards from `staged.checks`. Footer: primary "Looks right — add to Apple Health" (calls `importStaged`), ghost "Skip this night" (toss), microcopy "Writes 15 stage samples + 1 in-bed sample. Re-syncs never duplicate." Then dismiss.

### Metric review — `MetricCompareView.swift` (restyle, keep logic)
Same shell: header "<Kind>, side by side", chart card (existing Swift Charts comparison restyled: Google series sunDeep, Apple series plum/teal, soft gridlines), stat row (Google total/avg vs Apple, Δ), CheckCards, same import/skip footer with plain-language microcopy ("Adds 412 heart-rate points to Apple Health.").

### History — `HistoryView.swift` (new)
Header "What crossed over" + "A plain-language record of every sync." MiniStat 2×2 (🌉 nights bridged, 🛡 held back by checks, ♻️ duplicates blocked, 🔒 0 bytes off-device), timeline card as described in SyncLog section, HeadsUpCard variant at bottom ("If Google changes the API, affected nights show up here as held for review — never written quietly.").

### Settings — `SettingsView.swift` (new)
Header "Settings". Card "How syncing works": the two mode option cards (tap to select, checkmark circle on active; Automatic first and default). Card "Connection": status row (connected as you@gmail / not connected), Disconnect (destructive ghost) or Connect button; note about the weekly Testing-mode re-sign-in. Card "About": version 0.1.0, "On-device only — your data never touches a server", link-styled row to README/repo, HeadsUpCard. 

## Product name

The product is named **Airlift** (renamed from Airlift on 2026-06-12 — it "airlifts" Fitbit owners out of missing HealthKit support). ALL user-facing copy says Airlift, never Airlift. Internal names stay as-is: the Xcode project/scheme/target remain `Airlift`, bundle id remains `com.santekotturi.airlift`, and Swift type names don't need renaming.

## Quality bar (what "done" means)

Every screen screenshot at iPhone 17 Pro must show: correct Daybreak palette/typography (no default-List gray, no default blue buttons), no clipped/overlapping text, no missing data (every number real from the mock), edge states reachable without crashes, smooth animation code (no layout-thrash hacks), and the build + existing unit tests green. Swipe-to-toss must still exist on queue rows. Dark mode: force `.preferredColorScheme(.light)` at the shell (the palette is light by design; honest and intentional rather than half-broken dark support).
