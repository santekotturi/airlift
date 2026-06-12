#if DEBUG
import Foundation
import HealthKit

/// Canned fixtures for UI work, activated by the `-AirliftUIMock 1` launch
/// argument. Everything is built relative to `Date()` so "last night" is
/// always last night, and check results come from the real `SanityChecks` —
/// the screens render exactly what production code would produce.
@MainActor
enum UIMock {
    /// True when the app was launched with `-AirliftUIMock 1`.
    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: "AirliftUIMock")
    }

    /// `-AirliftUIMockScreen <home|session|metric|history|settings|priming>`.
    static var screen: String? {
        UserDefaults.standard.string(forKey: "AirliftUIMockScreen")
    }

    /// `-AirliftUIMockNoApple 1` strips every Apple-side fixture — the
    /// Fitbit + iPhone-only experience (no Apple Watch writing to HealthKit),
    /// with checks re-run so each screen shows its real no-comparison state.
    static var withoutAppleData: Bool {
        UserDefaults.standard.bool(forKey: "AirliftUIMockNoApple")
    }

    /// Seeds the engine and log with the fixture set, shaped to the user's
    /// sync mode: in automatic mode the clean items have already landed, so
    /// only what the engine itself would hold stays queued. The `metric`
    /// screen keeps the full queue so the pushed heart-rate batch exists.
    static func apply(engine: SyncEngine, log: SyncLogStore) {
        var sessions = stagedSessions()
        var metrics = stagedMetricBatches()
        if withoutAppleData {
            sessions = sessions.map { item in
                StagedSession(
                    session: item.session,
                    appleSleep: [],
                    heartRate: [],
                    checks: SanityChecks.run(google: item.session, appleSleep: [], heartRate: [])
                )
            }
            metrics = metrics.map { batch in
                StagedMetricBatch(
                    kind: batch.kind,
                    day: batch.day,
                    samples: batch.samples,
                    appleSamples: [],
                    checks: SanityChecks.runMetric(kind: batch.kind, samples: batch.samples, apple: []),
                    appleTotal: nil,
                    appleHourly: []
                )
            }
        }
        let automatic = engine.syncMode == .automatic && screen != "metric"
        if automatic {
            let total = sessions.count + metrics.count
            sessions.removeAll { $0.worstSeverity == .pass }
            metrics.removeAll { $0.worstSeverity == .pass }
            engine.applyUIMock(
                staged: sessions,
                stagedMetrics: metrics,
                status: .autoSynced(
                    written: total - sessions.count - metrics.count,
                    held: sessions.count + metrics.count,
                    date: Date()
                ),
                isConnected: true
            )
        } else {
            engine.applyUIMock(
                staged: sessions,
                stagedMetrics: metrics,
                status: .fetched(sessions: sessions.count, metricBatches: metrics.count, date: Date()),
                isConnected: true
            )
        }
        log.replaceAll(logEntries(automatic: automatic))
    }

    // MARK: - Sessions

    /// Two staged nights: last night (clean — every check passes) and an
    /// 11.2 h session three nights ago whose sparse stage coverage draws a
    /// real `SanityChecks` warning, so "held back by checks" is visible.
    static func stagedSessions() -> [StagedSession] {
        [lastNightSession(), heldSession()]
    }

    /// 23:38 → 07:02 (7 h 24 m), 15 contiguous segments shaped like a real
    /// hypnogram: deep early, REM late, two brief wakes.
    static func lastNightSession() -> StagedSession {
        let start = at(dayOffset: -1, hour: 23, minute: 38)
        let plan: [(SleepStage, Double)] = [
            (.light, 20), (.deep, 45), (.light, 25), (.deep, 40), (.light, 20),
            (.wake, 4), (.light, 30), (.rem, 25), (.light, 35), (.deep, 25),
            (.light, 30), (.rem, 35), (.wake, 5), (.light, 45), (.rem, 60),
        ]
        var cursor = start
        let stages = plan.map { stage, minutes in
            let segment = SleepStageSegment(stage: stage, start: cursor, end: cursor.addingTimeInterval(minutes * 60))
            cursor = segment.end
            return segment
        }
        let session = SleepSession(id: "uimock-night-a", start: start, end: cursor, stages: stages)

        // Apple Watch night: shadows the Fitbit hypnogram with minute-level
        // boundary jitter plus two honest disagreements (an early deep→core
        // handoff mid-night, an earlier final wake) → agreement ≈ 90%.
        let applePlan: [(HKCategoryValueSleepAnalysis, Double)] = [
            (.asleepCore, 14), (.asleepDeep, 43), (.asleepCore, 27), (.asleepDeep, 24),
            (.asleepCore, 36), (.awake, 5), (.asleepCore, 27), (.asleepREM, 27),
            (.asleepCore, 33), (.asleepDeep, 27), (.asleepCore, 27), (.asleepREM, 36),
            (.awake, 7), (.asleepCore, 43), (.asleepREM, 47), (.awake, 10),
        ]
        let apple = appleSegments(start: at(dayOffset: -1, hour: 23, minute: 45), plan: applePlan)
        let heartRate = overnightHeartRate(start: start, end: cursor)
        return StagedSession(
            session: session,
            appleSleep: apple,
            heartRate: heartRate,
            checks: SanityChecks.run(google: session, appleSleep: apple, heartRate: heartRate)
        )
    }

    /// Three nights ago, 21:55 → 09:07 (11.2 h) with stages covering only
    /// ~65 % of the session — the real stage-coverage check warns, so this is
    /// the night automatic mode holds back.
    static func heldSession() -> StagedSession {
        let start = at(dayOffset: -4, hour: 21, minute: 55)
        let end = at(dayOffset: -3, hour: 9, minute: 7)
        // Three contiguous blocks with two genuine recording holes between
        // them — coverage lands at 65% so the real check warns, and the strip
        // shows solid runs broken only where data is truly missing.
        let plan: [(SleepStage, Double, Double)] = [ // (stage, offset min, duration min)
            (.light, 0, 35), (.deep, 35, 50), (.light, 85, 30), (.wake, 115, 6),
            (.light, 121, 69),
            (.light, 330, 45), (.deep, 375, 30), (.light, 405, 95),
            (.light, 595, 32), (.rem, 627, 45),
        ]
        let stages = plan.map { stage, offset, minutes in
            SleepStageSegment(
                stage: stage,
                start: start.addingTimeInterval(offset * 60),
                end: start.addingTimeInterval((offset + minutes) * 60)
            )
        }
        let session = SleepSession(id: "uimock-night-b", start: start, end: end, stages: stages)
        let applePlan: [(HKCategoryValueSleepAnalysis, Double)] = [
            (.asleepCore, 50), (.asleepDeep, 40), (.asleepCore, 45), (.awake, 5),
            (.asleepCore, 60), (.asleepREM, 35), (.asleepCore, 50), (.asleepDeep, 25),
            (.asleepCore, 55), (.asleepREM, 45), (.awake, 6), (.asleepCore, 40),
            (.asleepREM, 30),
        ]
        let apple = appleSegments(start: at(dayOffset: -4, hour: 23, minute: 10), plan: applePlan)
        return StagedSession(
            session: session,
            appleSleep: apple,
            heartRate: [],
            checks: SanityChecks.run(google: session, appleSleep: apple, heartRate: [])
        )
    }

    // MARK: - Metric batches

    /// Five staged batches: heart rate, HRV, SpO₂ and respiratory rate for
    /// last night, plus yesterday's steps with Apple reference data.
    static func stagedMetricBatches() -> [StagedMetricBatch] {
        [heartRateBatch(), hrvBatch(), oxygenBatch(), respiratoryBatch(), stepsBatch()]
    }

    /// ~100 minute-averaged overnight points, avg ≈ 58 bpm.
    static func heartRateBatch() -> StagedMetricBatch {
        let day = at(dayOffset: 0, hour: 0, minute: 0)
        var samples: [MetricSample] = []
        var apple: [QuantitySample] = []
        for i in 0..<100 {
            let date = day.addingTimeInterval(Double(i) * 300) // 00:00 → 08:15
            let progress = Double(i) / 99
            let bpm = (62.5 - 7 * sin(progress * .pi) + 4 * sin(Double(i) * 1.7)).rounded()
            samples.append(MetricSample(id: "uimock-hr-\(i)", start: date, end: date.addingTimeInterval(60), value: max(47, bpm)))
            if i.isMultiple(of: 2) {
                apple.append(QuantitySample(id: UUID(), start: date, end: date, value: max(48, bpm + 1)))
            }
        }
        return batch(kind: .heartRate, day: day, samples: samples, apple: apple)
    }

    /// 8 overnight readings around 42 ms (RMSSD — the Apple comparison is
    /// informational by design).
    static func hrvBatch() -> StagedMetricBatch {
        let day = at(dayOffset: 0, hour: 0, minute: 0)
        let values: [Double] = [38, 41, 44, 39, 46, 43, 40, 45]
        let samples = values.enumerated().map { i, value in
            let date = day.addingTimeInterval(Double(i + 1) * 3600 / 1.2) // ~hourly 00:50 → 06:40
            return MetricSample(id: "uimock-hrv-\(i)", start: date, end: date, value: value)
        }
        let apple = [68.0, 74, 71].enumerated().map { i, value in
            QuantitySample(id: UUID(), start: day.addingTimeInterval(Double(i + 2) * 7200), end: day.addingTimeInterval(Double(i + 2) * 7200), value: value)
        }
        return batch(kind: .heartRateVariability, day: day, samples: samples, apple: apple)
    }

    /// 7 readings averaging ~96.4 %, dipping to 93 % once.
    static func oxygenBatch() -> StagedMetricBatch {
        let day = at(dayOffset: 0, hour: 0, minute: 0)
        let values: [Double] = [0.97, 0.96, 0.95, 0.93, 0.98, 0.97, 0.99]
        let samples = values.enumerated().map { i, value in
            let date = day.addingTimeInterval(3600 + Double(i) * 3600)
            return MetricSample(id: "uimock-spo2-\(i)", start: date, end: date, value: value)
        }
        let apple = [0.96, 0.97, 0.95].enumerated().map { i, value in
            QuantitySample(id: UUID(), start: day.addingTimeInterval(5400 + Double(i) * 7200), end: day.addingTimeInterval(5400 + Double(i) * 7200), value: value)
        }
        return batch(kind: .oxygenSaturation, day: day, samples: samples, apple: apple)
    }

    /// One daily aggregate of 14.2 breaths/min.
    static func respiratoryBatch() -> StagedMetricBatch {
        let day = at(dayOffset: 0, hour: 0, minute: 0)
        let samples = [MetricSample(id: "uimock-rr-0", start: day, end: day.addingTimeInterval(86_400), value: 14.2)]
        let apple = [QuantitySample(id: UUID(), start: day.addingTimeInterval(3 * 3600), end: day.addingTimeInterval(3 * 3600), value: 14.5)]
        return batch(kind: .respiratoryRate, day: day, samples: samples, apple: apple)
    }

    /// Yesterday's hourly steps, total 8 400 vs Apple's deduplicated 8 100.
    static func stepsBatch() -> StagedMetricBatch {
        let day = at(dayOffset: -1, hour: 0, minute: 0)
        let hourly: [Double] = [120, 260, 340, 480, 520, 610, 700, 850, 760, 690, 580, 640, 520, 460, 420, 450]
        let samples = hourly.enumerated().map { i, value in
            let start = day.addingTimeInterval(Double(7 + i) * 3600)
            return MetricSample(id: "uimock-steps-\(i)", start: start, end: start.addingTimeInterval(3600), value: value)
        }
        let appleHourly = hourly.enumerated().map { i, value in
            let start = day.addingTimeInterval(Double(7 + i) * 3600)
            return QuantitySample(id: UUID(), start: start, end: start.addingTimeInterval(3600), value: (value * 0.964).rounded())
        }
        let appleTotal = appleHourly.reduce(0) { $0 + $1.value }
        var item = batch(kind: .steps, day: day, samples: samples, apple: appleHourly, appleTotal: appleTotal)
        item.appleHourly = appleHourly
        return item
    }

    // MARK: - Log

    /// ~10 entries over the past 5 days telling the bridge's story, kept
    /// consistent with the queue: in automatic mode last night landed on its
    /// own this morning; in review mode it is still staged, so today only
    /// records the fetch.
    static func logEntries(automatic: Bool) -> [SyncLogEntry] {
        let tossWeekday = at(dayOffset: -3, hour: 9, minute: 30).formatted(.dateTime.weekday(.wide))
        var plan: [(Int, Int, Int, SyncLogEntry.Kind, String, String)] = [
            (0, 6, 42, .fetched, "Morning fetch finished",
             "Pulled the last 7 days from Google. Found 1 new night, skipped 1 already imported."),
            (-1, 7, 12, automatic ? .autoImported : .imported, "A clean night landed in Apple Health",
             automatic
                ? "7 h 13 m and 8,400 steps — every check passed, written without a tap."
                : "7 h 13 m and 8,400 steps — as approved by you."),
            (-1, 7, 10, .fetched, "Fetch finished",
             "1 night and 4 metric days staged from the last 7 days."),
            (-2, 8, 2, .held, "One night held for review",
             "Stages cover only 65% of an 11.2 h session — waiting for your OK."),
            (-2, 8, 1, .nothingNew, "Checked — nothing new",
             "Google had no new sleep data. Airlift will look again on next launch."),
            (-3, 9, 30, .tossed, "You skipped \(tossWeekday) night",
             "Google reported 11.2 h, outside your normal range. Nothing was written."),
            (-4, 7, 55, .imported, "427 heart-rate readings added",
             "Overnight heart rate, downsampled to one point per minute — as approved by you."),
            (-4, 7, 50, .fetched, "Fetch finished",
             "2 nights and 6 metric days staged from the last 7 days."),
            (-5, 18, 20, .connected, "Reconnected to Google",
             "Your weekly sign-in expired earlier today; the bridge is open again."),
            (-5, 8, 0, .error, "Reconnect needed",
             "Your weekly Google sign-in expired — fetches paused until you reconnect."),
        ]
        if automatic {
            plan.insert(
                (0, 6, 45, .autoImported, "Last night landed in Apple Health",
                 "7 h 24 m, 15 stage samples, plus heart rate, HRV and SpO₂ — every check passed, written without a tap."),
                at: 0
            )
        }
        return plan.map { dayOffset, hour, minute, kind, title, detail in
            SyncLogEntry(
                id: UUID(),
                date: at(dayOffset: dayOffset, hour: hour, minute: minute),
                kind: kind,
                title: title,
                detail: detail
            )
        }
    }

    // MARK: - Helpers

    private static func at(dayOffset: Int, hour: Int, minute: Int) -> Date {
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(dayOffset) * 86_400)
        return day.addingTimeInterval(Double(hour * 3600 + minute * 60))
    }

    private static func appleSegments(
        start: Date,
        plan: [(HKCategoryValueSleepAnalysis, Double)]
    ) -> [AppleSleepSegment] {
        var cursor = start
        return plan.map { value, minutes in
            let segment = AppleSleepSegment(
                id: UUID(),
                value: value,
                start: cursor,
                end: cursor.addingTimeInterval(minutes * 60),
                sourceName: "Apple Watch"
            )
            cursor = segment.end
            return segment
        }
    }

    /// Every 5 minutes across the night, 47–112 bpm: a settling spike early,
    /// a dip through the small hours, drifting up toward morning.
    private static func overnightHeartRate(start: Date, end: Date) -> [HRSample] {
        let count = Int(end.timeIntervalSince(start) / 300)
        return (0...count).map { i in
            let progress = Double(i) / Double(count)
            var bpm = 64 - 12 * sin(progress * .pi) + 4 * sin(Double(i) * 1.7)
            if i == 2 { bpm = 112 }
            return HRSample(id: UUID(), date: start.addingTimeInterval(Double(i) * 300), bpm: min(112, max(47, bpm.rounded())))
        }
    }

    private static func batch(
        kind: MetricKind,
        day: Date,
        samples: [MetricSample],
        apple: [QuantitySample],
        appleTotal: Double? = nil
    ) -> StagedMetricBatch {
        StagedMetricBatch(
            kind: kind,
            day: day,
            samples: samples,
            appleSamples: apple,
            checks: SanityChecks.runMetric(kind: kind, samples: samples, apple: apple, appleTotal: appleTotal),
            appleTotal: appleTotal
        )
    }
}
#endif
