#if DEBUG
import Foundation
import HealthKit

/// Fixture nights for the Recovery screen, activated by
/// `-AirliftUIMock 1 -AirliftUIMockScreen recovery`.
///
/// HealthKit in the simulator holds no overnight data at all, so without these
/// the screen only ever renders its empty state. Every night is driven by one
/// hidden nightly recovery value that both devices then measure through their
/// own noise — a fixture of pure noise would render a layout that proves
/// nothing, since the whole screen is about whether a signal survives.
///
/// Two things are modelled on purpose because the screen exists to show them:
///
/// * **Density.** Fitbit samples HRV every five minutes; the Watch manages
///   about four readings a night. That 17-to-1 gap is the finding, so the
///   fixture reproduces it rather than smoothing it away.
/// * **Staging disagreement.** Fitbit scores more of the night as deep than
///   Apple does. Switching the staging source has to visibly change the target
///   zone, or the control is decorative.
/// * **The switch to a watch that reads RMSSD itself.** The most recent
///   `nativeNights` nights also carry the Watch's own RMSSD every five minutes,
///   as an Ultra 4 on watchOS 27 writes it — so both the old spot-check layout
///   and the dense one can be seen without leaving the mock.
@MainActor
extension UIMock {

    static func apply(recovery: RecoveryEngine) {
        recovery.seed(
            recoveryNights(),
            probe: HeartbeatSeriesReader.Probe(
                isDataAvailable: true,
                authorization: .sharingAuthorized,
                seriesCount: 4 * 40,
                beatCount: 4 * 40 * 47,
                hrvSampleCount: 4 * 40
            )
        )
    }

    /// One sleep cycle, repeated: the shape both hypnograms are cut from.
    /// Apple's version under-calls deep, which is the thing being tested.
    private static let appleCycle: [(HKCategoryValueSleepAnalysis, Double)] = [
        (.asleepCore, 40), (.asleepDeep, 22), (.asleepCore, 12), (.asleepREM, 16),
    ]
    private static let fitbitCycle: [(HKCategoryValueSleepAnalysis, Double)] = [
        (.asleepCore, 32), (.asleepDeep, 34), (.asleepCore, 8), (.asleepREM, 16),
    ]

    /// Most recent nights recorded on a watch that writes its own RMSSD.
    static let nativeNights = 7

    static func recoveryNights(count: Int = 40) -> [NightSamples] {
        let calendar = Calendar.current
        let lastNight = calendar.startOfDay(for: Date())
        return (0..<count).compactMap { back -> NightSamples? in
            guard let night = calendar.date(byAdding: .day, value: -back, to: lastNight) else { return nil }
            return recoveryNight(night, index: back, calendar: calendar)
        }
        .sorted { $0.night < $1.night }
    }

    private static func recoveryNight(_ night: Date, index: Int, calendar: Calendar) -> NightSamples {
        let window = SyncEngine.metricDayInterval(
            kind: .heartRateVariability, day: night, calendar: calendar
        )
        // Lights out around 11pm, five cycles, up around 6:30.
        let bedtime = window.start.addingTimeInterval(5 * 3600 + noise(index, salt: 1) * 1800)
        let cycles = 5

        /// How recovered this night was, roughly −1 to +1. Everything below is
        /// a noisy view of this one number.
        let latent = sin(Double(index) * 0.7) * 0.6 + noise(index, salt: 2) * 0.7

        let appleSleep = segments(from: bedtime, cycle: appleCycle, cycles: cycles)
        let fitbitSleep = segments(from: bedtime, cycle: fitbitCycle, cycles: cycles)
        let appleIndex = StageIndex(apple: appleSleep)
        let sleepEnd = appleSleep.last?.end ?? bedtime.addingTimeInterval(7.5 * 3600)

        // Heart rate every 5 minutes — the dense series.
        var heartRate: [HRSample] = []
        var cursor = bedtime
        var step = 0
        while cursor < sleepEnd {
            let stage = appleIndex.stage(at: cursor)
            let stageOffset: Double = switch stage {
            case .deep: -3.5
            case .rem: 2.5
            case .awake: 6
            default: 0
            }
            let bpm = 58 - 5 * latent + stageOffset + noise(index * 997 + step, salt: 3) * 3
            heartRate.append(HRSample(id: UUID(), date: cursor, bpm: (bpm * 10).rounded() / 10))
            cursor.addTimeInterval(300)
            step += 1
        }

        // Fitbit HRV, also every 5 minutes, climbing through the night.
        var fitbitHRV: [HealthKitReader.OwnSample] = []
        cursor = bedtime
        step = 0
        while cursor < sleepEnd {
            let progress = cursor.timeIntervalSince(bedtime) / max(sleepEnd.timeIntervalSince(bedtime), 1)
            let rmssd = 44 * exp(0.22 * latent + 0.12 * progress + noise(index * 991 + step, salt: 4) * 0.18)
            fitbitHRV.append(
                HealthKitReader.OwnSample(
                    id: UUID(), start: cursor, end: cursor,
                    value: (rmssd * 10).rounded() / 10, dataPointID: nil
                )
            )
            cursor.addTimeInterval(300)
            step += 1
        }

        // Apple HRV: four readings a night, roughly two hours apart. This is
        // the density ceiling the whole screen is about.
        var appleHRV: [QuantitySample] = []
        var tachograms: [Tachogram] = []
        for reading in 0..<4 {
            let at = bedtime.addingTimeInterval(
                Double(reading) * 7200 + 1800 + noise(index * 89 + reading, salt: 5) * 900
            )
            guard at < sleepEnd else { continue }
            let rmssd = 42 * exp(0.22 * latent + noise(index * 89 + reading, salt: 6) * 0.3)
            // SDNN runs above RMSSD for the same beats, and carries extra noise
            // of its own: over a ~60 s window it absorbs any drift in heart rate
            // that happened to fall inside, and Apple barely filters artifacts
            // out first. Measured reliability is 0.18 against 0.54 for
            // recomputed RMSSD, so a fixture where SDNN is a clean multiple of
            // RMSSD would show the two agreeing perfectly and demonstrate the
            // opposite of what the screen exists to show.
            let sdnn = rmssd * 1.35 * exp(noise(index * 89 + reading, salt: 7) * 0.55)
            appleHRV.append(
                QuantitySample(id: UUID(), start: at, end: at, value: (sdnn * 10).rounded() / 10)
            )
            tachograms.append(tachogram(at: at, targetRMSSD: rmssd))
        }

        // The Watch's own RMSSD on the newest nights: the same five-minute
        // cadence as Fitbit, reading a little high, with noise of its own so
        // the two lines visibly disagree in places.
        var nativeRMSSD: [QuantitySample] = []
        if index < nativeNights {
            cursor = bedtime.addingTimeInterval(137)
            step = 0
            while cursor < sleepEnd {
                let progress = cursor.timeIntervalSince(bedtime) / max(sleepEnd.timeIntervalSince(bedtime), 1)
                let rmssd = 48 * exp(0.22 * latent + 0.12 * progress + noise(index * 983 + step, salt: 8) * 0.3)
                nativeRMSSD.append(
                    QuantitySample(
                        id: UUID(), start: cursor, end: cursor.addingTimeInterval(300),
                        value: rmssd.rounded(), algorithmVersion: 3
                    )
                )
                cursor.addTimeInterval(300)
                step += 1
            }
        }

        return NightSamples(
            night: night,
            window: window,
            appleSleep: appleSleep,
            airliftedSleep: fitbitSleep.map {
                HealthKitReader.OwnSample(
                    id: UUID(), start: $0.start, end: $0.end,
                    value: Double($0.value.rawValue), dataPointID: nil
                )
            },
            appleHeartRate: heartRate,
            appleHRV: appleHRV,
            airliftedHRV: fitbitHRV,
            tachograms: tachograms,
            appleNativeRMSSD: nativeRMSSD
        )
    }

    // MARK: - Building blocks

    private static func segments(
        from start: Date,
        cycle: [(HKCategoryValueSleepAnalysis, Double)],
        cycles: Int
    ) -> [AppleSleepSegment] {
        var cursor = start
        var segments: [AppleSleepSegment] = []
        for _ in 0..<cycles {
            for (value, minutes) in cycle {
                let end = cursor.addingTimeInterval(minutes * 60)
                segments.append(
                    AppleSleepSegment(
                        id: UUID(), value: value, start: cursor, end: end, sourceName: "Apple Watch"
                    )
                )
                cursor = end
            }
        }
        return segments
    }

    /// Beats whose successive differences are all exactly `targetRMSSD`
    /// milliseconds, so the recomputation has a known answer: intervals
    /// alternate 1.0 s and 1.0 s + target.
    private static func tachogram(at start: Date, targetRMSSD: Double) -> Tachogram {
        var beats = [Heartbeat(timeSinceSeriesStart: 0, precededByGap: false)]
        var time = 0.0
        for step in 0..<46 {
            time += step.isMultiple(of: 2) ? 1.0 : 1.0 + targetRMSSD / 1000
            beats.append(Heartbeat(timeSinceSeriesStart: time, precededByGap: false))
        }
        return Tachogram(start: start, beats: beats)
    }

    /// Deterministic jitter in −0.5…0.5. Fixtures have to look the same on
    /// every launch or a screenshot cannot be compared with the last one.
    private static func noise(_ index: Int, salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
        return value - value.rounded(.down) - 0.5
    }
}
#endif
