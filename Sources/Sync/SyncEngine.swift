import Foundation
import Observation

/// High-level sync state surfaced to the UI.
enum SyncStatus: Equatable {
    case idle
    /// In flight, with a live phase description ("Fetching Heart rate — page
    /// 37…") — first fetches page through minutes of intraday data and a
    /// frozen label reads as a hang.
    case syncing(phase: String)
    case needsConnection
    /// Data fetched from Google and staged for review — nothing written.
    case fetched(sessions: Int, metricBatches: Int, date: Date)
    /// Items written to HealthKit.
    case success(date: Date, written: Int)
    /// A gated sync pass finished: `written` items imported on their own,
    /// `held` items are waiting in the review queue.
    case autoSynced(written: Int, held: Int, date: Date)
    case failed(String)
}

/// One data type's live position in the fetch pipeline — drives the progress
/// list shown while a fetch is running.
struct PipelineItem: Identifiable, Equatable {
    enum Step: Equatable {
        case waiting
        case fetching(page: Int)
        /// Staging: decoding done, comparing against Apple Health + checks.
        case comparing
        case done(imported: Int, held: Int)
        case failed
    }

    /// Data type key ("sleep" or a `MetricKind` raw value).
    let id: String
    let name: String
    var step: Step = .waiting
}

/// A Google sleep session staged for human review, bundled with the Apple Watch
/// data for the same night and the sanity-check results comparing them.
/// Hashable so it can be a typed `navigationDestination` value.
struct StagedSession: Identifiable, Equatable, Hashable {
    let session: SleepSession
    let appleSleep: [AppleSleepSegment]
    let heartRate: [HRSample]
    let checks: [CheckResult]

    var id: String { session.id }

    /// Worst severity across all checks — drives the badge in the review list.
    var worstSeverity: CheckResult.Severity { checks.worstSeverity }
}

/// One day of one quantity metric staged for review, with Apple reference data.
/// Hashable so it can be a typed `navigationDestination` value.
struct StagedMetricBatch: Identifiable, Equatable, Hashable {
    let kind: MetricKind
    /// Start of the local calendar day the samples belong to.
    let day: Date
    let samples: [MetricSample]
    let appleSamples: [QuantitySample]
    let checks: [CheckResult]
    /// Apple's day total for cumulative kinds, deduplicated across overlapping
    /// iPhone/Watch sources by HealthKit (naively summing `appleSamples`
    /// double-counts). Nil for non-cumulative kinds.
    var appleTotal: Double? = nil
    /// Apple's deduplicated hourly sums for cumulative kinds — the honest
    /// chart series (raw `appleSamples` double-count). Empty otherwise.
    var appleHourly: [QuantitySample] = []

    var id: String { "\(kind.rawValue)|\(day.timeIntervalSinceReferenceDate)" }
    var worstSeverity: CheckResult.Severity { checks.worstSeverity }

    /// Headline number for the review list: total for cumulative metrics
    /// (steps), average otherwise.
    var aggregateDescription: String {
        guard !samples.isEmpty else { return "—" }
        if kind.isCumulative {
            return kind.format(samples.reduce(0) { $0 + $1.value })
        }
        let avg = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
        return "avg \(kind.format(avg))"
    }
}

extension [CheckResult] {
    var worstSeverity: CheckResult.Severity {
        if contains(where: { $0.severity == .fail }) { return .fail }
        if contains(where: { $0.severity == .warn }) { return .warn }
        return .pass
    }
}

/// Orchestrates the bridge in *review-first* mode: fetch Google sessions, stage
/// them alongside Apple Watch reference data and sanity checks, and only write
/// to HealthKit on an explicit per-session `importStaged` — or discard with
/// `toss`. Tossed and imported IDs persist so sessions never reappear.
///
/// `syncNow` (fetch → write everything, no review) is kept for the future
/// automated mode once the data source is trusted, but nothing calls it today.
@MainActor
@Observable
final class SyncEngine {
    private(set) var status: SyncStatus = .idle
    private(set) var isConnected: Bool

    /// Sessions awaiting review, newest first.
    private(set) var staged: [StagedSession] = []

    /// Metric batches (one per kind per day) awaiting review, newest first.
    private(set) var stagedMetrics: [StagedMetricBatch] = []

    /// Per-data-type progress through the current fetch (shown while syncing).
    private(set) var pipeline: [PipelineItem] = []

    /// True when the branded notification primer should be on screen — set
    /// after a successful connect while iOS permission is still undetermined;
    /// cleared by accept/decline. The sheet, not the system prompt, goes first.
    private(set) var needsNotificationPriming = false

    /// Most recent raw page JSON per data type (pretty-printed). Populated to
    /// verify the pre-GA wire schemas during bring-up; shown in DEBUG builds.
    private(set) var lastRawJSON: [String: String] = [:]

    /// Persisted high-water mark, for display when no sync has run this launch.
    var lastSyncedDate: Date? { state.lastSyncedDate }

    /// How much review stands between fetch and write. Stored mirror of the
    /// persisted setting so the UI picker is observable; writes flow back.
    var syncMode: SyncMode {
        didSet { settings.syncMode = syncMode }
    }

    /// Which quantity metrics sync at all (observable mirror, persisted).
    var enabledKinds: Set<MetricKind> {
        didSet { settings.enabledKinds = enabledKinds }
    }

    /// Per-(kind, day) sync outcomes — powers the coverage grid.
    let ledger: SyncLedgerStoring

    /// Plain-language history ("What crossed over").
    let log: SyncLogStore

    /// Posts/clears the "reconnect needed" local notification.
    private let notifier: ReconnectNotifying

    /// Persists raw pages + staged items to Documents/Dumps (DEBUG only).
    private let dump = DumpStore()

    private let oauth: OAuthClient
    private let api: GoogleHealthClient
    private let writer: HealthKitWriter
    private let reader: HealthKitReader
    private let tokens: TokenStoring
    private let dedup: DedupStoring
    private let tossed: DedupStoring
    private var state: SyncStateStoring
    private var settings: SyncSettingsStoring
    private var healthAuthorized = false

    #if DEBUG
    /// True when the engine runs on seeded UI-mock fixtures — every
    /// side-effecting path (HealthKit, network, dedup/ledger persistence)
    /// becomes a no-op. Set via `applyUIMock`.
    private(set) var isUIMock = false
    /// Seeds restored after each mock fetch replay.
    private var mockStagedSeed: [StagedSession] = []
    private var mockMetricsSeed: [StagedMetricBatch] = []
    #endif

    init(
        oauth: OAuthClient,
        api: GoogleHealthClient,
        writer: HealthKitWriter,
        reader: HealthKitReader,
        tokens: TokenStoring,
        dedup: DedupStoring,
        tossed: DedupStoring,
        state: SyncStateStoring,
        settings: SyncSettingsStoring,
        ledger: SyncLedgerStoring,
        log: SyncLogStore,
        notifier: ReconnectNotifying
    ) {
        self.oauth = oauth
        self.api = api
        self.writer = writer
        self.reader = reader
        self.tokens = tokens
        self.dedup = dedup
        self.tossed = tossed
        self.state = state
        self.settings = settings
        self.ledger = ledger
        self.log = log
        self.notifier = notifier
        self.syncMode = settings.syncMode
        self.enabledKinds = settings.enabledKinds
        self.isConnected = tokens.load() != nil
    }

    // MARK: - Connection

    /// Runs the OAuth consent flow and stores the resulting tokens.
    func connect() async {
        #if DEBUG
        if isUIMock {
            isConnected = true
            status = .idle
            log.record(.connected, title: "Connected to Google Health", detail: "The bridge is open — fetches can begin.")
            needsNotificationPriming = true
            return
        }
        #endif
        do {
            let stored = try await oauth.authorize()
            try tokens.save(stored)
            isConnected = true
            status = .idle
            Log.sync.info("Connected to Google Health")
            log.record(.connected, title: "Connected to Google Health", detail: "The bridge is open — fetches can begin.")
            await notifier.clearReconnectNeeded()
            // Prime now, not at first launch — the user just connected, so
            // "tell me when this sign-in expires" is an easy yes. The branded
            // sheet explains what's coming before iOS asks.
            if await notifier.isAuthorizationUndetermined() {
                needsNotificationPriming = true
            }
        } catch OAuthError.userCancelled {
            // Leave state untouched on cancel.
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Connect failed: \(error.localizedDescription)")
        }
    }

    /// Forgets all credentials (used by the "reconnect" path).
    func disconnect() {
        #if DEBUG
        if isUIMock {
            isConnected = false
            status = .needsConnection
            return
        }
        #endif
        try? tokens.clear()
        isConnected = false
        status = .needsConnection
    }

    // MARK: - Review flow (fetch → stage → import/toss)

    /// Explicit fetch of the last `days` days ("Fetch again · last 7 days").
    /// Gated by the configured mode like every other pass — in automatic mode
    /// clean items land on their own, in review-everything nothing is written.
    func fetchForReview(days: Int = 7, now: Date = Date()) async {
        await run(since: now.addingTimeInterval(-Double(days) * 86_400), now: now, mode: syncMode)
    }

    /// The main sync path: fetch since the high-water mark (with the usual
    /// re-pull window), then gate each staged item through the configured
    /// mode — auto-importing what the checks trust and holding the rest for
    /// review. Called on launch and from the background task.
    func syncNow(now: Date = Date()) async {
        let since = SyncWindow.fetchSince(lastSynced: state.lastSyncedDate, now: now)
        await run(since: since, now: now, mode: syncMode)
    }

    /// Shared fetch → stage → gate pass.
    ///
    /// Sleep failing is fatal for the pass; individual metric kinds failing are
    /// logged and skipped so one flaky pre-GA endpoint can't blank the queue.
    private func run(since: Date, now: Date, mode: SyncMode) async {
        #if DEBUG
        if isUIMock {
            await mockSyncPass(now: now)
            return
        }
        #endif
        guard tokens.load() != nil else {
            status = .needsConnection
            return
        }

        status = .syncing(phase: "Starting…")
        rawPageCounts = [:]
        // A re-fetch re-stages anything still unresolved; only newly held
        // items deserve a history line.
        let previouslyHeld = Set(staged.map(\.id)).union(stagedMetrics.map(\.id))
        let kinds = MetricKind.allCases.filter { enabledKinds.contains($0) }
        pipeline = [PipelineItem(id: "sleep", name: "Sleep")]
            + kinds.map { PipelineItem(id: $0.rawValue, name: $0.displayName) }
        dump.beginFetch(now: now)
        do {
            try await ensureHealthAuthorized()

            #if DEBUG
            status = .syncing(phase: "Warming up the engine…")
            await runDiscoveryProbes(since: since)
            #endif

            var written = 0

            // Sleep sessions.
            status = .syncing(phase: "Fetching sleep…")
            setPipelineStep("sleep", .fetching(page: 1))
            let sessions = try await withFreshToken { token in
                try await self.api.fetchSleepSessions(since: since, accessToken: token, onRawPage: self.captureRaw(key: "sleep"))
            }
            setPipelineStep("sleep", .comparing)
            let freshCandidates = sessions.filter {
                $0.isComplete && !dedup.contains($0.id) && !tossed.contains($0.id)
            }
            var heldSessions: [StagedSession] = []
            var sleepImported = 0
            for (index, session) in freshCandidates.enumerated() {
                status = .syncing(phase: "Comparing sleep night \(index + 1) of \(freshCandidates.count) with Apple Health…")
                let item = await stage(session)
                dump.writeStagedSession(item)
                let day = CivilDay.string(from: item.session.end)
                switch SyncGate.action(for: item.worstSeverity, mode: mode) {
                case .autoImport:
                    do {
                        try await writer.write(item.session)
                        dedup.insert(item.id)
                        ledger.recordSynced(kind: sleepLedgerKind, day: day, samples: 1, at: now)
                        sleepImported += 1
                        log.record(
                            .autoImported,
                            title: "\(Self.nightName(for: item.session.end)) landed in Apple Health",
                            detail: "\(Self.durationText(item.session)) of sleep, \(item.session.stages.count) stage samples — all checks passed."
                        )
                    } catch {
                        // Write failed — keep it reviewable instead of losing it.
                        heldSessions.append(item)
                        ledger.set(.quarantined, kind: sleepLedgerKind, day: day)
                        Log.sync.error("Auto-import failed for session \(item.id): \(error.localizedDescription)")
                    }
                case .review:
                    heldSessions.append(item)
                    ledger.set(SyncGate.heldStatus(for: item.worstSeverity), kind: sleepLedgerKind, day: day)
                    if mode == .automatic, !previouslyHeld.contains(item.id) {
                        let flagged = item.checks.filter { $0.severity == .warn || $0.severity == .fail }
                        log.record(
                            .held,
                            title: "\(Self.nightName(for: item.session.end)) held for review",
                            detail: flagged.first.map { "\($0.name): \($0.detail)" } ?? "Waiting for your OK before it's written."
                        )
                    }
                }
            }
            staged = heldSessions.sorted { $0.session.start > $1.session.start }
            written += sleepImported
            setPipelineStep("sleep", .done(imported: sleepImported, held: heldSessions.count))

            // Quantity metrics — best-effort per kind.
            var heldBatches: [StagedMetricBatch] = []
            var failedKinds: Set<MetricKind> = []
            for kind in kinds {
                status = .syncing(phase: "Fetching \(kind.displayName)…")
                setPipelineStep(kind.rawValue, .fetching(page: 1))
                do {
                    let samples = try await withFreshToken { token in
                        try await self.api.fetchMetricSamples(kind, since: since, accessToken: token, onRawPage: self.captureRaw(key: kind.rawValue, fetchingName: kind.displayName))
                    }
                    status = .syncing(phase: "Comparing \(kind.displayName) with Apple Health…")
                    setPipelineStep(kind.rawValue, .comparing)
                    var imported = 0
                    var importedSamples = 0
                    var held = 0
                    for batch in await stageMetric(kind, samples: samples) {
                        dump.writeStagedBatch(batch)
                        let day = CivilDay.string(from: batch.day)
                        switch SyncGate.action(for: batch.worstSeverity, mode: mode) {
                        case .autoImport:
                            do {
                                try await writer.write(batch.samples, kind: kind)
                                dedup.insertAll(batch.samples.map(\.id))
                                ledger.recordSynced(kind: kind.rawValue, day: day, samples: batch.samples.count, at: now)
                                imported += 1
                                importedSamples += batch.samples.count
                            } catch {
                                heldBatches.append(batch)
                                ledger.set(.quarantined, kind: kind.rawValue, day: day)
                                Log.sync.error("Auto-import failed for \(batch.id): \(error.localizedDescription)")
                                held += 1
                            }
                        case .review:
                            heldBatches.append(batch)
                            ledger.set(SyncGate.heldStatus(for: batch.worstSeverity), kind: kind.rawValue, day: day)
                            held += 1
                            if mode == .automatic, !previouslyHeld.contains(batch.id) {
                                let flagged = batch.checks.first { $0.severity == .warn || $0.severity == .fail }
                                log.record(
                                    .held,
                                    title: "\(kind.displayName) for \(Self.dayText(batch.day)) held for review",
                                    detail: flagged.map { "\($0.name): \($0.detail)" } ?? "Waiting for your OK before it's written."
                                )
                            }
                        }
                    }
                    written += imported
                    // One history line per kind per pass — per-day lines would
                    // flood the timeline on a first 7-day sync.
                    if importedSamples > 0 {
                        log.record(
                            .autoImported,
                            title: "\(kind.displayName) added to Apple Health",
                            detail: "\(importedSamples) readings across \(imported) day(s) — all checks passed."
                        )
                    }
                    setPipelineStep(kind.rawValue, .done(imported: imported, held: held))
                } catch {
                    failedKinds.insert(kind)
                    setPipelineStep(kind.rawValue, .failed)
                    dump.writeText("\(error)\n\n\(error.localizedDescription)", name: "google-\(kind.rawValue)-ERROR.txt")
                    Log.sync.error("Fetch failed for \(kind.rawValue): \(error.localizedDescription) — skipping")
                }
            }
            stagedMetrics = heldBatches.sorted {
                ($0.day, $0.kind.displayName) > ($1.day, $1.kind.displayName)
            }

            // Days the pass covered but nothing arrived for: mark "no data from
            // the device" so the coverage grid can tell a quiet band from a
            // failed sync. Today is excluded — it is still accumulating.
            let yesterday = now.addingTimeInterval(-86_400)
            if yesterday >= since {
                for day in CivilDay.days(from: since, through: yesterday) {
                    ledger.fillIfEmpty(.noData, kind: sleepLedgerKind, day: day)
                    for kind in kinds where !failedKinds.contains(kind) {
                        ledger.fillIfEmpty(.noData, kind: kind.rawValue, day: day)
                    }
                }
            }

            // Advance the high-water mark, but never past unresolved items —
            // a held item must keep falling inside the next fetch window so an
            // app restart can't strand it. Review-everything passes don't
            // advance (nothing was written; the window must not move).
            if mode == .automatic {
                let oldestHeld = (staged.map(\.session.end) + stagedMetrics.map(\.day)).min()
                state.lastSyncedDate = min(now, oldestHeld ?? now)
            }

            let heldCount = staged.count + stagedMetrics.count
            if mode == .reviewEverything {
                status = .fetched(sessions: staged.count, metricBatches: stagedMetrics.count, date: now)
            } else {
                status = .autoSynced(written: written, held: heldCount, date: now)
            }
            let newlyHeld = (staged.map(\.id) + stagedMetrics.map(\.id))
                .filter { !previouslyHeld.contains($0) }
                .count
            if written == 0 && newlyHeld == 0 {
                log.record(.nothingNew, title: "Checked — nothing new", detail: "Google had no new data. Airlift will look again on next launch.")
            } else if mode == .reviewEverything {
                log.record(.fetched, title: "Fetch finished", detail: "\(staged.count) night(s) and \(stagedMetrics.count) metric day(s) are ready for review.")
            }
            Log.sync.info("Sync pass done — imported \(written), held \(heldCount) for review")
        } catch OAuthError.noRefreshToken {
            disconnect()
            log.record(.error, title: "Reconnect needed", detail: "Your weekly Google sign-in expired — reconnect to keep the bridge open.")
            await notifier.postReconnectNeeded()
        } catch let error as OAuthError {
            status = .needsConnection
            log.record(.error, title: "Reconnect needed", detail: "Google turned down the sign-in — reconnect to keep the bridge open.")
            Log.sync.error("Auth error during fetch: \(error.localizedDescription)")
            await notifier.postReconnectNeeded()
        } catch {
            status = .failed(error.localizedDescription)
            log.record(.error, title: "Fetch didn't finish", detail: error.localizedDescription)
            Log.sync.error("Fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Notification priming

    /// "Turn on notifications" on the primer — hands off to the system prompt.
    func acceptNotifications() async {
        needsNotificationPriming = false
        #if DEBUG
        if isUIMock { return } // never show a real system prompt over fixtures
        #endif
        await notifier.requestAuthorization()
    }

    /// "Not now" (or a swipe-down). Permission stays undetermined, so the
    /// primer naturally re-offers after the next weekly reconnect.
    func declineNotifications() {
        needsNotificationPriming = false
    }

    #if DEBUG
    /// Shows the primer over seeded fixtures (`-AirliftUIMockScreen priming`).
    func primeNotificationsForUIMock() {
        needsNotificationPriming = true
    }
    #endif

    // MARK: - History phrasing

    private static func nightName(for end: Date) -> String {
        if Calendar.current.isDateInToday(end) { return "Last night" }
        if Calendar.current.isDateInYesterday(end) { return "Yesterday's night" }
        return "\(end.formatted(.dateTime.weekday(.wide))) night"
    }

    private static func durationText(_ session: SleepSession) -> String {
        let minutes = Int(session.end.timeIntervalSince(session.start) / 60)
        return "\(minutes / 60) h \(minutes % 60) m"
    }

    private static func dayText(_ day: Date) -> String {
        day.formatted(date: .abbreviated, time: .omitted)
    }

    #if DEBUG
    /// One-fetch diagnostic sweep, dumped alongside the regular payloads:
    /// - the server's data-type catalog (`users/me/dataTypes`)
    /// - sleep with NO filter — an in-progress/malformed session has no
    ///   `civil_end_time`, so the regular filtered fetch would hide it
    /// - candidate metric paths, each saved as `probe <path> HTTP<status>.json`
    ///   so a folder listing reads as a result table
    private func runDiscoveryProbes(since: Date) async {
        do {
            let catalog = try await withFreshToken { token in
                try await self.api.fetchDataTypeCatalog(accessToken: token)
            }
            dump.writeRawPage(catalog, dataType: "dataTypes-catalog")
        } catch {
            dump.writeText("\(error)", name: "probe dataTypes-catalog ERROR.txt")
            Log.sync.error("dataTypes catalog probe failed: \(error.localizedDescription)")
        }

        // "sleep" (unfiltered) first — catches late/unfinalized sessions the
        // civil_end_time filter would hide. The rest are documented kebab-case
        // type IDs we don't bridge yet; their payloads inform future mappings.
        let candidates = [
            "sleep",
            "respiratory-rate-sleep-summary",
            "daily-heart-rate-variability",
            "daily-oxygen-saturation",
            "active-zone-minutes",
            "calories", "energy-expended",
            "exercise", "weight", "vo2-max", "nutrition-log",
        ]
        for path in candidates {
            do {
                let (status, body) = try await withFreshToken { token in
                    try await self.api.probeDataPoints(dataTypePath: path, filterDate: nil, accessToken: token)
                }
                dump.writeProbe(path: path, status: status, body: body)
            } catch {
                dump.writeText("\(error)", name: "probe \(path) ERROR.txt")
            }
        }
        Log.sync.info("Discovery probes complete (\(candidates.count) paths)")
    }
    #endif

    /// Groups one metric's samples into per-day batches with Apple reference
    /// data and checks. High-frequency kinds are downsampled first (so dedup
    /// keys are bucket IDs); already-imported/tossed IDs are filtered out.
    private func stageMetric(_ kind: MetricKind, samples: [MetricSample]) async -> [StagedMetricBatch] {
        var samples = samples
        if let bucket = kind.downsampleBucketSeconds {
            samples = samples.downsampled(bucket: bucket, kind: kind)
        }
        let fresh = samples.filter { !dedup.contains($0.id) && !tossed.contains($0.id) }
        guard !fresh.isEmpty else { return [] }

        let calendar = Calendar.current
        let byDay = Dictionary(grouping: fresh) { calendar.startOfDay(for: $0.start) }
        var batches: [StagedMetricBatch] = []
        for (day, daySamples) in byDay {
            let interval = DateInterval(start: day, duration: 86_400)
            let apple = (try? await reader.quantitySamples(kind, in: interval)) ?? []
            let appleTotal = kind.isCumulative
                ? try? await reader.cumulativeTotal(kind, in: interval)
                : nil
            let appleHourly = kind.isCumulative
                ? (try? await reader.hourlyTotals(kind, in: interval)) ?? []
                : []
            let sorted = daySamples.sorted { $0.start < $1.start }
            batches.append(StagedMetricBatch(
                kind: kind,
                day: day,
                samples: sorted,
                appleSamples: apple,
                checks: SanityChecks.runMetric(kind: kind, samples: sorted, apple: apple, appleTotal: appleTotal),
                appleTotal: appleTotal,
                appleHourly: appleHourly
            ))
        }
        return batches
    }

    /// Loads the Apple-side reference data for a session and runs sanity checks.
    private func stage(_ session: SleepSession) async -> StagedSession {
        // Look 6h either side so a shifted-timezone Apple night still shows up.
        let window = DateInterval(
            start: session.start.addingTimeInterval(-6 * 3600),
            end: session.end.addingTimeInterval(6 * 3600)
        )
        let appleSleep = (try? await reader.sleepSegments(overlapping: window)) ?? []
        let sessionInterval = DateInterval(start: session.start, end: session.end)
        let heartRate = (try? await reader.heartRate(in: sessionInterval)) ?? []
        return StagedSession(
            session: session,
            appleSleep: appleSleep,
            heartRate: heartRate,
            checks: SanityChecks.run(google: session, appleSleep: appleSleep, heartRate: heartRate)
        )
    }

    /// Sweeps the review queue, importing every staged item whose checks
    /// raised no warnings or failures (pass/info only); flagged items stay
    /// queued. Covers items staged before a switch to automatic mode — fresh
    /// fetches gate inline. Call after fetches and on launch only when the
    /// stored mode is `.automatic`.
    func autoImportClean() async {
        let cleanSessions = staged.filter { $0.worstSeverity == .pass }
        let cleanBatches = stagedMetrics.filter { $0.worstSeverity == .pass }
        guard !cleanSessions.isEmpty || !cleanBatches.isEmpty else { return }

        #if DEBUG
        if isUIMock {
            for item in cleanSessions {
                staged.removeAll { $0.id == item.id }
                log.record(
                    .autoImported,
                    title: "\(Self.nightName(for: item.session.end)) landed in Apple Health",
                    detail: "\(Self.durationText(item.session)) of sleep, \(item.session.stages.count) stage samples — all checks passed."
                )
            }
            for batch in cleanBatches {
                stagedMetrics.removeAll { $0.id == batch.id }
                log.record(
                    .autoImported,
                    title: "\(batch.kind.displayName) added to Apple Health",
                    detail: "\(batch.samples.count) readings — all checks passed."
                )
            }
            return
        }
        #endif

        do { try await ensureHealthAuthorized() } catch { return }
        let now = Date()
        for item in cleanSessions {
            do {
                try await writer.write(item.session)
                dedup.insert(item.id)
                staged.removeAll { $0.id == item.id }
                ledger.recordSynced(kind: sleepLedgerKind, day: CivilDay.string(from: item.session.end), samples: 1, at: now)
                log.record(
                    .autoImported,
                    title: "\(Self.nightName(for: item.session.end)) landed in Apple Health",
                    detail: "\(Self.durationText(item.session)) of sleep, \(item.session.stages.count) stage samples — all checks passed."
                )
            } catch {
                Log.sync.error("Auto-import failed for session \(item.id): \(error.localizedDescription)")
            }
        }
        for batch in cleanBatches {
            do {
                try await writer.write(batch.samples, kind: batch.kind)
                dedup.insertAll(batch.samples.map(\.id))
                stagedMetrics.removeAll { $0.id == batch.id }
                ledger.recordSynced(kind: batch.kind.rawValue, day: CivilDay.string(from: batch.day), samples: batch.samples.count, at: now)
                log.record(
                    .autoImported,
                    title: "\(batch.kind.displayName) added to Apple Health",
                    detail: "\(batch.samples.count) readings from \(Self.dayText(batch.day)) — all checks passed."
                )
            } catch {
                Log.sync.error("Auto-import failed for \(batch.id): \(error.localizedDescription)")
            }
        }
    }

    /// Writes one reviewed session to HealthKit and retires it from the queue.
    func importStaged(_ id: String) async {
        guard let item = staged.first(where: { $0.id == id }) else { return }
        #if DEBUG
        if isUIMock {
            staged.removeAll { $0.id == id }
            status = .success(date: Date(), written: 1)
            log.record(
                .imported,
                title: "\(Self.nightName(for: item.session.end)) added to Apple Health",
                detail: "\(Self.durationText(item.session)) of sleep, \(item.session.stages.count) stage samples — you approved it."
            )
            return
        }
        #endif
        do {
            try await writer.write(item.session)
            dedup.insert(id)
            staged.removeAll { $0.id == id }
            ledger.recordSynced(
                kind: sleepLedgerKind,
                day: CivilDay.string(from: item.session.end),
                samples: 1,
                at: Date()
            )
            status = .success(date: Date(), written: 1)
            log.record(
                .imported,
                title: "\(Self.nightName(for: item.session.end)) added to Apple Health",
                detail: "\(Self.durationText(item.session)) of sleep, \(item.session.stages.count) stage samples — you approved it."
            )
            Log.sync.info("Imported session \(id)")
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Import failed for \(id): \(error.localizedDescription)")
        }
    }

    /// Discards a staged session. The ID is persisted so it never reappears.
    func toss(_ id: String) {
        #if DEBUG
        if isUIMock {
            if let item = staged.first(where: { $0.id == id }) {
                log.record(
                    .tossed,
                    title: "You skipped \(Self.nightName(for: item.session.end).lowercased())",
                    detail: "Google reported \(Self.durationText(item.session)) — nothing was written, and it won't come back."
                )
            }
            staged.removeAll { $0.id == id }
            return
        }
        #endif
        if let item = staged.first(where: { $0.id == id }) {
            ledger.set(.tossed, kind: sleepLedgerKind, day: CivilDay.string(from: item.session.end))
            log.record(
                .tossed,
                title: "You skipped \(Self.nightName(for: item.session.end).lowercased())",
                detail: "Google reported \(Self.durationText(item.session)) — nothing was written, and it won't come back."
            )
        }
        tossed.insert(id)
        staged.removeAll { $0.id == id }
        Log.sync.info("Tossed session \(id)")
    }

    /// Writes one reviewed metric batch to HealthKit and retires it.
    func importMetricBatch(_ id: String) async {
        guard let batch = stagedMetrics.first(where: { $0.id == id }) else { return }
        #if DEBUG
        if isUIMock {
            stagedMetrics.removeAll { $0.id == id }
            status = .success(date: Date(), written: batch.samples.count)
            log.record(
                .imported,
                title: "\(batch.kind.displayName) for \(Self.dayText(batch.day)) added to Apple Health",
                detail: "\(batch.samples.count) readings — you approved it."
            )
            return
        }
        #endif
        do {
            try await writer.write(batch.samples, kind: batch.kind)
            dedup.insertAll(batch.samples.map(\.id))
            stagedMetrics.removeAll { $0.id == id }
            ledger.recordSynced(
                kind: batch.kind.rawValue,
                day: CivilDay.string(from: batch.day),
                samples: batch.samples.count,
                at: Date()
            )
            status = .success(date: Date(), written: batch.samples.count)
            log.record(
                .imported,
                title: "\(batch.kind.displayName) for \(Self.dayText(batch.day)) added to Apple Health",
                detail: "\(batch.samples.count) readings — you approved it."
            )
            Log.sync.info("Imported \(batch.samples.count) \(batch.kind.rawValue) sample(s)")
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Metric import failed for \(id): \(error.localizedDescription)")
        }
    }

    /// Discards a staged metric batch; all its sample IDs persist as tossed.
    func tossMetricBatch(_ id: String) {
        guard let batch = stagedMetrics.first(where: { $0.id == id }) else { return }
        #if DEBUG
        if isUIMock {
            stagedMetrics.removeAll { $0.id == id }
            log.record(
                .tossed,
                title: "You skipped \(batch.kind.displayName.lowercased()) for \(Self.dayText(batch.day))",
                detail: "Nothing was written, and it won't come back."
            )
            return
        }
        #endif
        tossed.insertAll(batch.samples.map(\.id))
        stagedMetrics.removeAll { $0.id == id }
        ledger.set(.tossed, kind: batch.kind.rawValue, day: CivilDay.string(from: batch.day))
        log.record(
            .tossed,
            title: "You skipped \(batch.kind.displayName.lowercased()) for \(Self.dayText(batch.day))",
            detail: "Nothing was written, and it won't come back."
        )
        Log.sync.info("Tossed metric batch \(id)")
    }

    // MARK: - Fetch & tokens

    /// Runs `operation` with a valid access token, transparently refreshing and
    /// retrying once on 401.
    private func withFreshToken<T>(_ operation: (String) async throws -> T) async throws -> T {
        let token = try await validAccessToken()
        do {
            return try await operation(token)
        } catch GoogleHealthError.unauthorized {
            Log.sync.notice("401 from Health API — forcing token refresh and retrying once")
            let refreshed = try await forceRefresh()
            return try await operation(refreshed)
        }
    }

    /// Pages received per data type this fetch — drives the live phase label.
    private var rawPageCounts: [String: Int] = [:]

    /// `@Sendable` sink for raw page JSON: written to the dump folder verbatim,
    /// stored per data type for the debug schema viewer, and (when
    /// `fetchingName` is set) surfaced as paging progress in the status.
    private func captureRaw(key: String, fetchingName: String? = nil) -> @Sendable (Data) -> Void {
        { [weak self, dump] data in
            dump.writeRawPage(data, dataType: key)
            let pretty = Self.prettyPrint(data)
            Task { @MainActor in self?.noteRawPage(key: key, fetchingName: fetchingName, pretty: pretty) }
        }
    }

    private func noteRawPage(key: String, fetchingName: String?, pretty: String) {
        lastRawJSON[key] = pretty
        rawPageCounts[key, default: 0] += 1
        // Only narrate while still syncing — pages can land after a failure.
        guard case .syncing = status, let pages = rawPageCounts[key] else { return }
        if case .fetching = pipeline.first(where: { $0.id == key })?.step {
            setPipelineStep(key, .fetching(page: pages))
        }
        if let fetchingName, pages > 1 {
            status = .syncing(phase: "Fetching \(fetchingName) — page \(pages)…")
        }
    }

    private func setPipelineStep(_ id: String, _ step: PipelineItem.Step) {
        guard let index = pipeline.firstIndex(where: { $0.id == id }) else { return }
        pipeline[index].step = step
    }

    nonisolated private static func prettyPrint(_ data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: pretty, encoding: .utf8)
        else {
            return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        }
        return string
    }

    /// Returns a valid access token, refreshing if it has expired.
    private func validAccessToken() async throws -> String {
        guard let stored = tokens.load() else { throw OAuthError.noRefreshToken }
        if stored.isAccessTokenValid() { return stored.accessToken }
        return try await forceRefresh()
    }

    private func forceRefresh() async throws -> String {
        guard let stored = tokens.load() else { throw OAuthError.noRefreshToken }
        let refreshed = try await oauth.refresh(stored)
        try tokens.save(refreshed)
        return refreshed.accessToken
    }

    private func ensureHealthAuthorized() async throws {
        guard !healthAuthorized else { return }
        try await writer.requestAuthorization()
        healthAuthorized = true
    }
}

#if DEBUG
// MARK: - UI mock (declared here: `private(set)` setters are file-scoped)

extension SyncEngine {
    /// Seeds the engine with canned fixtures and flips it into UI-mock mode:
    /// imports/tosses retire items and log without touching HealthKit or the
    /// dedup/ledger stores, fetches replay a canned pipeline, connect and
    /// disconnect just flip state. No HealthKit prompt can ever appear.
    func applyUIMock(
        staged: [StagedSession],
        stagedMetrics: [StagedMetricBatch],
        status: SyncStatus,
        isConnected: Bool
    ) {
        isUIMock = true
        mockStagedSeed = staged
        mockMetricsSeed = stagedMetrics
        self.staged = staged
        self.stagedMetrics = stagedMetrics
        self.status = status
        self.isConnected = isConnected
    }

    /// Canned fetch: walks every data type waiting → fetching → comparing →
    /// done (~0.4 s each), then restores the seeded queue.
    fileprivate func mockSyncPass(now: Date) async {
        status = .syncing(phase: "Fetching sleep…")
        pipeline = [PipelineItem(id: "sleep", name: "Sleep")]
            + MetricKind.allCases.map { PipelineItem(id: $0.rawValue, name: $0.displayName) }
        for item in pipeline {
            status = .syncing(phase: "Fetching \(item.name)…")
            setPipelineStep(item.id, .fetching(page: 1))
            try? await Task.sleep(for: .milliseconds(200))
            status = .syncing(phase: "Comparing \(item.name) with Apple Health…")
            setPipelineStep(item.id, .comparing)
            try? await Task.sleep(for: .milliseconds(200))
            let held = item.id == "sleep"
                ? mockStagedSeed.count
                : mockMetricsSeed.filter { $0.kind.rawValue == item.id }.count
            setPipelineStep(item.id, .done(imported: 0, held: held))
        }
        staged = mockStagedSeed
        stagedMetrics = mockMetricsSeed
        status = .fetched(sessions: staged.count, metricBatches: stagedMetrics.count, date: now)
        log.record(
            .fetched,
            title: "Fetch finished",
            detail: "\(staged.count) night(s) and \(stagedMetrics.count) metric day(s) are ready for review."
        )
    }
}
#endif
