import Foundation
import HealthKit
import Observation

/// Drives the Recovery screen: pulls a stretch of nights out of HealthKit once,
/// then recomputes the comparison locally whenever the staging source or stage
/// selection changes.
///
/// The split matters. Reading is slow and hits HealthKit; staging and
/// statistics are pure functions over data already in memory. Caching the raw
/// nights means switching from Apple's hypnogram to Fitbit's — the comparison
/// this screen exists to make — is instant rather than a fresh minute of
/// querying, so the two can be flipped between and actually compared.
@MainActor
@Observable
final class RecoveryEngine {
    enum State {
        case idle
        case loading(step: String)
        case ready(RecoveryReport)
        case failed(String)

        var report: RecoveryReport? {
            if case .ready(let report) = self { return report }
            return nil
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    /// Nights read by default. Long enough for the correlations to mean
    /// something — below roughly 30 the interval is wider than any difference
    /// between the metrics — and short enough to stay one quick read.
    static let defaultNightCount = 60

    private(set) var state: State = .idle
    private(set) var nightCount = RecoveryEngine.defaultNightCount

    /// Toggling either of these rebuilds the report from the cached nights.
    var selection: StageSelection = .coreAndDeep {
        didSet { if selection != oldValue { rebuild() } }
    }
    var staging: StagingSource = .apple {
        didSet { if staging != oldValue { rebuild() } }
    }

    private let reader: HealthKitReader
    private let heartbeats: HeartbeatSeriesReader
    private let writer: HealthKitWriter?
    private let calendar: Calendar
    private var cached: [NightSamples] = []
    private var probe: HeartbeatSeriesReader.Probe?
    private var didAuthorize = false

    init(
        reader: HealthKitReader,
        heartbeats: HeartbeatSeriesReader = HeartbeatSeriesReader(),
        writer: HealthKitWriter? = nil,
        calendar: Calendar = .current
    ) {
        self.reader = reader
        self.heartbeats = heartbeats
        self.writer = writer
        self.calendar = calendar
    }

    /// Asks for Health access before the first read.
    ///
    /// Without this the screen is a trap: HealthKit answers an unauthorized
    /// read with an empty result and no error, so beat-to-beat series the user
    /// was simply never asked about would come back as zero and read as "the
    /// Watch does not publish them". Sync requests the same permissions, but a
    /// user can reach this screen first.
    private func authorizeIfNeeded() async {
        guard !didAuthorize, let writer else { return }
        didAuthorize = true
        try? await writer.requestAuthorization()
    }

    /// Reads `nights` back from last night and builds the first report.
    func load(nights: Int = RecoveryEngine.defaultNightCount) async {
        nightCount = nights
        state = .loading(step: "Checking Health access…")
        await authorizeIfNeeded()
        state = .loading(step: "Reading sleep and heart rate…")
        do {
            let window = Self.span(nights: nights, calendar: calendar)
            let samples = try await fetch(span: window)
            state = .loading(step: "Reading beat-to-beat series…")
            // The one genuinely unknown call. It is allowed to come back empty
            // — that is a finding about the Watch, not a failure to report.
            let probe = await heartbeats.probe(window)
            let tachograms = probe.seriesCount > 0
                ? ((try? await heartbeats.tachograms(in: window)) ?? [])
                : []

            cached = Self.assemble(
                span: window, samples: samples, tachograms: tachograms, calendar: calendar
            )
            self.probe = probe
            rebuild()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Recomputes the report from cached nights — no HealthKit, no waiting.
    private func rebuild() {
        guard !cached.isEmpty else {
            if case .loading = state { return }
            state = .ready(.empty(selection: selection, staging: staging))
            return
        }
        let nights = cached.map { $0.recovery(selection: selection, staging: staging) }
        let charts = cached.map { $0.chart(selection: selection, staging: staging) }
        // The HRV comparison is window-level, so the stage *selection* does not
        // filter it — each window carries its own stage and the screen groups by
        // that. Only the staging source matters here.
        let windows = cached.flatMap { $0.hrvWindows(staging: staging) }
        let fitbitCounts = cached.map { Double($0.fitbitHRVSampleCount(staging: staging)) }
        state = .ready(
            RecoveryReport.build(
                nights: nights, charts: charts,
                hrv: HRVReport.build(
                    windows: windows,
                    fitbitSamplesPerNight: RecoveryStats.median(fitbitCounts.filter { $0 > 0 })
                ),
                selection: selection, staging: staging, probe: probe
            )
        )
    }

    // MARK: - Reading

    /// Everything read in one pass, before it is cut into nights.
    struct RawSpan {
        var appleSleep: [AppleSleepSegment] = []
        var airliftedSleep: [HealthKitReader.OwnSample] = []
        var heartRate: [HRSample] = []
        var appleHRV: [QuantitySample] = []
        var airliftedHRV: [HealthKitReader.OwnSample] = []
        var rmssd: [QuantitySample] = []
    }

    /// One query per data type across the whole span, rather than six per
    /// night. Sixty nights is 360 round trips the other way.
    private func fetch(span: DateInterval) async throws -> RawSpan {
        var raw = RawSpan()
        raw.appleSleep = try await reader.sleepSegments(overlapping: span)
        raw.airliftedSleep = try await reader.importedSleepSamples(endingIn: span)
        raw.heartRate = try await reader.heartRate(in: span)
        // Named directly: Airlift's HRV kind moves to RMSSD on iOS 27, but
        // Apple's spot checks stay SDNN.
        raw.appleHRV = try await reader.quantitySamples(
            MetricKind.legacyHRVIdentifier, unit: MetricKind.heartRateVariability.hkUnit, in: span
        )
        raw.airliftedHRV = try await reader.importedQuantitySamples(.heartRateVariability, in: span)
        raw.rmssd = try await reader.rmssdSamples(in: span)
        return raw
    }

    /// The instant range covering `nights` nights back from last night, on the
    /// same 6pm→6pm boundary every overnight metric already uses.
    static func span(nights: Int, calendar: Calendar = .current, now: Date = Date()) -> DateInterval {
        let lastNight = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -max(nights - 1, 0), to: lastNight) ?? lastNight
        let start = SyncEngine.metricDayInterval(
            kind: .heartRateVariability, day: first, calendar: calendar
        ).start
        let end = SyncEngine.metricDayInterval(
            kind: .heartRateVariability, day: lastNight, calendar: calendar
        ).end
        return DateInterval(start: start, end: max(end, start))
    }

    /// Cuts the span into nights on the overnight-day key, so a night that
    /// crosses midnight stays one night — the same rule the sync engine labels
    /// HRV with.
    ///
    /// Each stream is also routed to the device that measured it. Apple's side
    /// takes only what an Apple device recorded, and only the spot-check SDNN;
    /// Fitbit's side prefers Airlift's import and falls back, night by night,
    /// to what another app (Google Health) wrote into Health directly, so a
    /// night synced either way is still compared — and never both at once.
    nonisolated static func assemble(
        span: DateInterval,
        samples: RawSpan,
        tachograms: [Tachogram],
        calendar: Calendar
    ) -> [NightSamples] {
        func key(_ date: Date) -> Date {
            SyncEngine.metricDayKey(kind: .heartRateVariability, start: date, calendar: calendar)
        }
        func imported(_ sample: QuantitySample) -> HealthKitReader.OwnSample {
            HealthKitReader.OwnSample(
                id: sample.id, start: sample.start, end: sample.end, value: sample.value, dataPointID: nil
            )
        }
        func imported(_ segment: AppleSleepSegment) -> HealthKitReader.OwnSample {
            HealthKitReader.OwnSample(
                id: segment.id, start: segment.start, end: segment.end,
                value: Double(segment.value.rawValue), dataPointID: nil
            )
        }

        let appleSleep = Dictionary(grouping: samples.appleSleep.filter(\.fromAppleDevice)) { key($0.start) }
        let otherSleep = Dictionary(grouping: samples.appleSleep.filter { !$0.fromAppleDevice }) { key($0.start) }
        let airliftedSleep = Dictionary(grouping: samples.airliftedSleep) { key($0.start) }
        // Airlift's own Fitbit heart rate, and Google Health's, live in the same
        // type; "Apple heart rate" has to mean the Watch's.
        let heartRate = Dictionary(grouping: samples.heartRate.filter(\.fromAppleDevice)) { key($0.date) }
        let appleHRV = Dictionary(
            grouping: samples.appleHRV.filter { $0.fromAppleDevice && !$0.isContinuousHRV }
        ) { key($0.start) }
        let airliftedHRV = Dictionary(grouping: samples.airliftedHRV) { key($0.start) }
        let nativeRMSSD = Dictionary(grouping: samples.rmssd.filter(\.fromAppleDevice)) { key($0.start) }
        let otherRMSSD = Dictionary(grouping: samples.rmssd.filter { !$0.fromAppleDevice }) { key($0.start) }
        let beats = Dictionary(grouping: tachograms) { key($0.start) }

        // Every night that any source saw something on, so a night missing from
        // one device still shows up as a gap instead of vanishing.
        var nights = Set(appleSleep.keys)
        nights.formUnion(airliftedSleep.keys)
        nights.formUnion(otherSleep.keys)
        nights.formUnion(heartRate.keys)
        nights.formUnion(appleHRV.keys)
        nights.formUnion(airliftedHRV.keys)
        nights.formUnion(nativeRMSSD.keys)
        nights.formUnion(otherRMSSD.keys)

        return nights.sorted().compactMap { night -> NightSamples? in
            let window = SyncEngine.metricDayInterval(
                kind: .heartRateVariability, day: night, calendar: calendar
            )
            guard span.intersects(window) else { return nil }
            let fitbitSleep = airliftedSleep[night] ?? (otherSleep[night] ?? []).map(imported)
            let fitbitHRV = airliftedHRV[night] ?? (otherRMSSD[night] ?? []).map(imported)
            return NightSamples(
                night: night,
                window: window,
                appleSleep: appleSleep[night] ?? [],
                airliftedSleep: fitbitSleep,
                appleHeartRate: (heartRate[night] ?? []).sorted { $0.date < $1.date },
                appleHRV: (appleHRV[night] ?? []).sorted { $0.start < $1.start },
                airliftedHRV: fitbitHRV.sorted { $0.start < $1.start },
                tachograms: (beats[night] ?? []).sorted { $0.start < $1.start },
                appleNativeRMSSD: (nativeRMSSD[night] ?? []).sorted { $0.start < $1.start }
            )
        }
    }

    #if DEBUG
    /// Seeds the engine with fixtures so the screen can be driven in the
    /// simulator, where HealthKit holds no overnight data at all.
    func seed(_ nights: [NightSamples], probe: HeartbeatSeriesReader.Probe? = nil) {
        cached = nights
        self.probe = probe
        rebuild()
    }
    #endif
}
