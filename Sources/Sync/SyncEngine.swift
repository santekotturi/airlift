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
        case done(staged: Int)
        case failed
    }

    /// Data type key ("sleep" or a `MetricKind` raw value).
    let id: String
    let name: String
    var step: Step = .waiting
}

/// A Google sleep session staged for human review, bundled with the Apple Watch
/// data for the same night and the sanity-check results comparing them.
struct StagedSession: Identifiable, Equatable {
    let session: SleepSession
    let appleSleep: [AppleSleepSegment]
    let heartRate: [HRSample]
    let checks: [CheckResult]

    var id: String { session.id }

    /// Worst severity across all checks — drives the badge in the review list.
    var worstSeverity: CheckResult.Severity { checks.worstSeverity }
}

/// One day of one quantity metric staged for review, with Apple reference data.
struct StagedMetricBatch: Identifiable, Equatable {
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

    /// Most recent raw page JSON per data type (pretty-printed). Populated to
    /// verify the pre-GA wire schemas during bring-up; shown in DEBUG builds.
    private(set) var lastRawJSON: [String: String] = [:]

    /// Persisted high-water mark, for display when no sync has run this launch.
    var lastSyncedDate: Date? { state.lastSyncedDate }

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
    private var healthAuthorized = false

    init(
        oauth: OAuthClient,
        api: GoogleHealthClient,
        writer: HealthKitWriter,
        reader: HealthKitReader,
        tokens: TokenStoring,
        dedup: DedupStoring,
        tossed: DedupStoring,
        state: SyncStateStoring
    ) {
        self.oauth = oauth
        self.api = api
        self.writer = writer
        self.reader = reader
        self.tokens = tokens
        self.dedup = dedup
        self.tossed = tossed
        self.state = state
        self.isConnected = tokens.load() != nil
    }

    // MARK: - Connection

    /// Runs the OAuth consent flow and stores the resulting tokens.
    func connect() async {
        do {
            let stored = try await oauth.authorize()
            try tokens.save(stored)
            isConnected = true
            status = .idle
            Log.sync.info("Connected to Google Health")
        } catch OAuthError.userCancelled {
            // Leave state untouched on cancel.
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Connect failed: \(error.localizedDescription)")
        }
    }

    /// Forgets all credentials (used by the "reconnect" path).
    func disconnect() {
        try? tokens.clear()
        isConnected = false
        status = .needsConnection
    }

    // MARK: - Review flow (fetch → stage → import/toss)

    /// Fetches Google sleep sessions **and all quantity metrics** from the last
    /// `days` days and stages everything for review with Apple Watch reference
    /// data. **Writes nothing.**
    ///
    /// Sleep failing is fatal for the fetch; individual metric kinds failing are
    /// logged and skipped so one flaky pre-GA endpoint can't blank the queue.
    func fetchForReview(days: Int = 7, now: Date = Date()) async {
        guard tokens.load() != nil else {
            status = .needsConnection
            return
        }

        status = .syncing(phase: "Starting…")
        rawPageCounts = [:]
        pipeline = [PipelineItem(id: "sleep", name: "Sleep")]
            + MetricKind.allCases.map { PipelineItem(id: $0.rawValue, name: $0.displayName) }
        dump.beginFetch(now: now)
        do {
            try await ensureHealthAuthorized()
            let since = now.addingTimeInterval(-Double(days) * 86_400)

            #if DEBUG
            status = .syncing(phase: "Probing API schemas (debug)…")
            await runDiscoveryProbes(since: since)
            #endif

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
            var freshSessions: [StagedSession] = []
            for (index, session) in freshCandidates.enumerated() {
                status = .syncing(phase: "Comparing sleep night \(index + 1) of \(freshCandidates.count) with Apple Health…")
                let item = await stage(session)
                dump.writeStagedSession(item)
                freshSessions.append(item)
            }
            staged = freshSessions.sorted { $0.session.start > $1.session.start }
            setPipelineStep("sleep", .done(staged: freshSessions.count))

            // Quantity metrics — best-effort per kind.
            var freshBatches: [StagedMetricBatch] = []
            for kind in MetricKind.allCases {
                status = .syncing(phase: "Fetching \(kind.displayName)…")
                setPipelineStep(kind.rawValue, .fetching(page: 1))
                do {
                    let samples = try await withFreshToken { token in
                        try await self.api.fetchMetricSamples(kind, since: since, accessToken: token, onRawPage: self.captureRaw(key: kind.rawValue, fetchingName: kind.displayName))
                    }
                    status = .syncing(phase: "Comparing \(kind.displayName) with Apple Health…")
                    setPipelineStep(kind.rawValue, .comparing)
                    let batches = await stageMetric(kind, samples: samples)
                    for batch in batches { dump.writeStagedBatch(batch) }
                    freshBatches.append(contentsOf: batches)
                    setPipelineStep(kind.rawValue, .done(staged: batches.count))
                } catch {
                    setPipelineStep(kind.rawValue, .failed)
                    dump.writeText("\(error)\n\n\(error.localizedDescription)", name: "google-\(kind.rawValue)-ERROR.txt")
                    Log.sync.error("Fetch failed for \(kind.rawValue): \(error.localizedDescription) — skipping")
                }
            }
            stagedMetrics = freshBatches.sorted {
                ($0.day, $0.kind.displayName) > ($1.day, $1.kind.displayName)
            }

            status = .fetched(sessions: staged.count, metricBatches: stagedMetrics.count, date: now)
            Log.sync.info("Staged \(self.staged.count) session(s) + \(self.stagedMetrics.count) metric batch(es) for review")
        } catch OAuthError.noRefreshToken {
            disconnect()
        } catch let error as OAuthError {
            status = .needsConnection
            Log.sync.error("Auth error during fetch: \(error.localizedDescription)")
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Fetch failed: \(error.localizedDescription)")
        }
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

    /// Writes one reviewed session to HealthKit and retires it from the queue.
    func importStaged(_ id: String) async {
        guard let item = staged.first(where: { $0.id == id }) else { return }
        do {
            try await writer.write(item.session)
            dedup.insert(id)
            staged.removeAll { $0.id == id }
            status = .success(date: Date(), written: 1)
            Log.sync.info("Imported session \(id)")
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Import failed for \(id): \(error.localizedDescription)")
        }
    }

    /// Discards a staged session. The ID is persisted so it never reappears.
    func toss(_ id: String) {
        tossed.insert(id)
        staged.removeAll { $0.id == id }
        Log.sync.info("Tossed session \(id)")
    }

    /// Writes one reviewed metric batch to HealthKit and retires it.
    func importMetricBatch(_ id: String) async {
        guard let batch = stagedMetrics.first(where: { $0.id == id }) else { return }
        do {
            try await writer.write(batch.samples, kind: batch.kind)
            dedup.insertAll(batch.samples.map(\.id))
            stagedMetrics.removeAll { $0.id == id }
            status = .success(date: Date(), written: batch.samples.count)
            Log.sync.info("Imported \(batch.samples.count) \(batch.kind.rawValue) sample(s)")
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Metric import failed for \(id): \(error.localizedDescription)")
        }
    }

    /// Discards a staged metric batch; all its sample IDs persist as tossed.
    func tossMetricBatch(_ id: String) {
        guard let batch = stagedMetrics.first(where: { $0.id == id }) else { return }
        tossed.insertAll(batch.samples.map(\.id))
        stagedMetrics.removeAll { $0.id == id }
        Log.sync.info("Tossed metric batch \(id)")
    }

    // MARK: - Automated sync (future mode — unused until data is trusted)

    /// Fetch → write everything new, no review. Kept for the automation milestone;
    /// not called from launch or background while data is still being validated.
    @discardableResult
    func syncNow(now: Date = Date()) async -> SyncStatus {
        guard tokens.load() != nil else {
            status = .needsConnection
            return status
        }

        status = .syncing(phase: "Syncing…")
        do {
            try await ensureHealthAuthorized()
            let written = try await runSync(now: now)
            state.lastSyncedDate = now
            status = .success(date: now, written: written)
            Log.sync.info("Sync complete — wrote \(written) new session(s)")
        } catch OAuthError.noRefreshToken {
            disconnect()
        } catch let error as OAuthError {
            status = .needsConnection
            Log.sync.error("Auth error during sync: \(error.localizedDescription)")
        } catch {
            status = .failed(error.localizedDescription)
            Log.sync.error("Sync failed: \(error.localizedDescription)")
        }
        return status
    }

    /// Fetch → map → write. Returns the number of newly written sessions.
    private func runSync(now: Date) async throws -> Int {
        let since = SyncWindow.fetchSince(lastSynced: state.lastSyncedDate, now: now)
        let sessions = try await withFreshToken { token in
            try await self.api.fetchSleepSessions(since: since, accessToken: token, onRawPage: self.captureRaw(key: "sleep"))
        }

        var written = 0
        for session in sessions where session.isComplete {
            guard !dedup.contains(session.id), !tossed.contains(session.id) else { continue }
            try await writer.write(session)
            dedup.insert(session.id)
            written += 1
        }
        return written
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
