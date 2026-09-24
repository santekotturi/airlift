import XCTest
import HealthKit
@testable import Airlift

/// The Watch's own RMSSD (watchOS 27, Ultra 4): keeping it apart from the
/// spot-check SDNN it shares a night with, pairing it with Fitbit window by
/// window, and routing every stream to the device that actually measured it.
final class NativeRMSSDTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Ultra4NightFixture.timeZone
        return calendar
    }

    private func at(_ seconds: Int) -> Date {
        Ultra4NightFixture.base.addingTimeInterval(TimeInterval(seconds))
    }

    private var span: DateInterval {
        DateInterval(start: Ultra4NightFixture.base, duration: 86_400)
    }

    private func fixtureRaw() -> RecoveryEngine.RawSpan {
        var raw = RecoveryEngine.RawSpan()
        raw.appleSleep = Ultra4NightFixture.sleep.map { start, end, value in
            AppleSleepSegment(
                id: UUID(), value: value, start: at(start), end: at(end),
                sourceName: "Apple Watch Ultra 4"
            )
        }
        raw.appleHRV = Ultra4NightFixture.sdnn.map { start, end, ms, version in
            QuantitySample(id: UUID(), start: at(start), end: at(end), value: ms, algorithmVersion: version)
        }
        raw.rmssd = Ultra4NightFixture.rmssd.map { start, end, ms in
            QuantitySample(id: UUID(), start: at(start), end: at(end), value: ms, algorithmVersion: 3)
        }
        return raw
    }

    private func assemble(_ raw: RecoveryEngine.RawSpan, tachograms: [Tachogram] = []) throws -> NightSamples {
        let nights = RecoveryEngine.assemble(span: span, samples: raw, tachograms: tachograms, calendar: calendar)
        return try XCTUnwrap(nights.first { !$0.appleNativeRMSSD.isEmpty })
    }

    /// Fitbit on its 5-minute grid, reading `ratio` of whatever the Watch said
    /// in the window around each grid point.
    private func fitbitGrid(following night: NightSamples, ratio: Double) -> [HealthKitReader.OwnSample] {
        night.appleNativeRMSSD.compactMap { reading in
            let grid = (reading.start.timeIntervalSince1970 / 300).rounded(.up) * 300
            let instant = Date(timeIntervalSince1970: grid)
            guard instant <= reading.end else { return nil }
            return HealthKitReader.OwnSample(
                id: UUID(), start: instant, end: instant, value: reading.value * ratio, dataPointID: nil
            )
        }
    }

    // MARK: - Reading the real night

    func testSpotCheckSDNNIsKeptApartFromTheContinuousSeries() throws {
        let night = try assemble(fixtureRaw())
        let spotChecks = Ultra4NightFixture.sdnn.filter { $0.3 < 3 }.count
        XCTAssertEqual(night.appleHRV.count, spotChecks)
        XCTAssertTrue(night.appleHRV.allSatisfy { !$0.isContinuousHRV })
        XCTAssertEqual(night.appleNativeRMSSD.count, Ultra4NightFixture.rmssd.count)
    }

    func testTheWatchReadsAtFitbitsCadenceAsleep() throws {
        let night = try assemble(fixtureRaw())
        let index = night.stageIndex(.apple)
        let asleep = night.appleNativeRMSSD.filter { index.stage(at: $0.start)?.isAsleep == true }
        // The old ceiling was four or five a night. This night is ~90.
        XCTAssertGreaterThan(asleep.count, 80)
    }

    func testNightlyWatchRMSSDIsTheMeanOfItsReadingsInZone() throws {
        let recovery = try assemble(fixtureRaw()).recovery(selection: .allSleep, staging: .apple)
        let native = try XCTUnwrap(recovery.appleNativeRMSSD)
        XCTAssertGreaterThan(native.sampleCount, 60)
        XCTAssertNotNil(native.halves, "90 readings a night always split into two halves")
        XCTAssertEqual(native.value, 72.4, accuracy: 6, "Python over the same export: 88 asleep readings, mean 72.4 ms, before the onset trim")
    }

    // MARK: - Windows

    func testNativeReadingsAnchorTheWindows() throws {
        let night = try assemble(fixtureRaw())
        let windows = night.hrvWindows(staging: .apple)
        XCTAssertEqual(windows.filter { $0.appleNative != nil }.count, night.appleNativeRMSSD.count)
        XCTAssertEqual(Set(windows.map(\.id)).count, windows.count)
    }

    func testEachWatchWindowPairsWithTheFitbitReadingInsideIt() throws {
        var raw = fixtureRaw()
        let bare = try assemble(raw)
        raw.airliftedHRV = fitbitGrid(following: bare, ratio: 0.8)
        let windows = try assemble(raw).hrvWindows(staging: .apple).filter { $0.appleNative != nil }

        let paired = windows.filter { $0.fitbit != nil }
        XCTAssertGreaterThan(paired.count, 90)
        XCTAssertTrue(paired.allSatisfy { $0.fitbitSampleCount == 1 }, "One Fitbit grid point per 5-minute window")
        for window in paired {
            XCTAssertEqual(try XCTUnwrap(window.nativeErrorPct), 25, accuracy: 1e-6)
        }
    }

    func testReportSummarisesWatchAgainstFitbit() throws {
        var raw = fixtureRaw()
        raw.airliftedHRV = fitbitGrid(following: try assemble(raw), ratio: 0.8)
        let windows = try assemble(raw).hrvWindows(staging: .apple)
        let report = HRVReport.build(windows: windows, fitbitSamplesPerNight: 90)

        XCTAssertTrue(report.hasNative)
        XCTAssertEqual(try XCTUnwrap(report.nativeOverall.spearman), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(report.nativeOverall.ratioBiasPct), 25, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(report.nativeReadingsPerNight), Double(Ultra4NightFixture.rmssd.count))
        XCTAssertFalse(report.zones.isEmpty)
        XCTAssertNotNil(report.zones.first?.nativeSpearman)
    }

    func testASpotCheckInsideAWatchWindowRidesAlong() throws {
        let night = try assemble(fixtureRaw())
        let host = try XCTUnwrap(night.appleNativeRMSSD.first { $0.end.timeIntervalSince($0.start) >= 240 })
        let inside = tachogram(at: host.start.addingTimeInterval(60), jitterMS: 40)
        let outside = tachogram(at: at(3 * 3600), jitterMS: 50) // 9pm, before the Watch's first reading
        let samples = try assemble(fixtureRaw(), tachograms: [inside, outside])

        let windows = samples.hrvWindows(staging: .apple)
        XCTAssertEqual(windows.count, samples.appleNativeRMSSD.count + 1, "The outside spot check keeps its own window")
        let hosted = try XCTUnwrap(windows.first { $0.appleDerived != nil && $0.appleNative != nil })
        XCTAssertEqual(try XCTUnwrap(hosted.appleDerived), 40, accuracy: 0.001)
        XCTAssertEqual(hosted.appleNative, host.value)
        let alone = try XCTUnwrap(windows.first { $0.appleNative == nil })
        XCTAssertEqual(try XCTUnwrap(alone.appleDerived), 50, accuracy: 0.001)
    }

    func testOlderWatchNightsAreUnchanged() throws {
        var raw = fixtureRaw()
        raw.rmssd = []
        let night = try XCTUnwrap(
            RecoveryEngine.assemble(span: span, samples: raw, tachograms: [tachogram(at: at(8 * 3600), jitterMS: 40)], calendar: calendar).first
        )
        let windows = night.hrvWindows(staging: .apple)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].appleNative)
        XCTAssertEqual(night.chart(selection: .allSleep, staging: .apple).appleKind, .recomputed)
    }

    func testChartDrawsTheWatchsOwnRMSSDWhenItExists() throws {
        let chart = try assemble(fixtureRaw()).chart(selection: .allSleep, staging: .apple)
        XCTAssertEqual(chart.appleKind, .native)
        XCTAssertEqual(chart.apple.count, Ultra4NightFixture.rmssd.count)
    }

    // MARK: - Routing by device

    func testAnotherAppsRMSSDStandsInForFitbitOnlyWhenAirliftHasNone() throws {
        var raw = fixtureRaw()
        let google = QuantitySample(
            id: UUID(), start: at(8 * 3600), end: at(8 * 3600), value: 55,
            fromAppleDevice: false, sourceName: "Google Health"
        )
        raw.rmssd.append(google)
        let viaGoogle = try assemble(raw)
        XCTAssertEqual(viaGoogle.airliftedHRV.map(\.value), [55])
        XCTAssertFalse(viaGoogle.appleNativeRMSSD.contains { $0.id == google.id })

        raw.airliftedHRV = [
            HealthKitReader.OwnSample(id: UUID(), start: at(8 * 3600), end: at(8 * 3600), value: 61, dataPointID: nil),
        ]
        XCTAssertEqual(try assemble(raw).airliftedHRV.map(\.value), [61], "Never both at once")
    }

    func testAnotherAppsSleepIsFitbitsNotApples() throws {
        var raw = fixtureRaw()
        raw.appleSleep.append(
            AppleSleepSegment(
                id: UUID(), value: .asleepDeep, start: at(6 * 3600), end: at(7 * 3600),
                sourceName: "Google Health", fromAppleDevice: false
            )
        )
        let night = try assemble(raw)
        XCTAssertEqual(night.appleSleep.count, Ultra4NightFixture.sleep.count)
        XCTAssertEqual(night.airliftedSleep.count, 1)
        XCTAssertEqual(night.stageIndex(.fitbit).stage(at: at(6 * 3600 + 60)), .deep)
    }

    func testOnlyTheWatchsHeartRateCountsAsApples() throws {
        var raw = fixtureRaw()
        raw.heartRate = [
            HRSample(id: UUID(), date: at(8 * 3600), bpm: 52),
            HRSample(id: UUID(), date: at(8 * 3600 + 60), bpm: 60, fromAppleDevice: false),
        ]
        XCTAssertEqual(try assemble(raw).appleHeartRate.map(\.bpm), [52])
    }

    // MARK: - Nightly comparison

    func testRecoveryReportComparesWatchRMSSDWithFitbitInMilliseconds() {
        let nights = (0..<8).map { day -> NightRecovery in
            let fitbit = 40 + Double(day * 3)
            let value = { (v: Double) in SeriesValue(value: v, sampleCount: 90, halfA: v, halfB: v) }
            return NightRecovery(
                night: Date(timeIntervalSince1970: Double(day) * 86_400),
                window: DateInterval(start: Date(timeIntervalSince1970: Double(day) * 86_400), duration: 86_400),
                selection: .allSleep, staging: .apple,
                fitbitRMSSD: value(fitbit), appleRMSSD: nil, appleSDNN: nil,
                appleNativeRMSSD: value(fitbit * 1.1),
                stagedHeartRate: nil, stagedMinutes: 400, hasStaging: true
            )
        }
        let report = RecoveryReport.build(nights: nights, selection: .allSleep, staging: .apple, probe: nil)
        let comparison = try? XCTUnwrap(report.comparison(.appleNativeRMSSD))
        XCTAssertEqual(comparison?.summary.n, 8)
        XCTAssertTrue(comparison?.showsBias == true)
        XCTAssertEqual(comparison?.summary.ratioBiasPct ?? 0, 10, accuracy: 0.01)
    }

    // MARK: - Zones

    /// A window missing one series must drop out of that series' correlation
    /// only — not shift every later pair against the wrong Fitbit value.
    func testZoneCorrelationsPairWindowByWindow() throws {
        let windows = (0..<8).map { offset in
            HRVWindow(
                id: offset, night: Ultra4NightFixture.base, at: at(offset * 300), stage: .core,
                applePublished: nil,
                appleDerived: offset.isMultiple(of: 3) ? nil : 30 + Double(offset),
                fitbit: 40 + Double(offset),
                fitbitSampleCount: 1, rejectionRate: nil, successivePairs: 0,
                appleNative: 50 + Double(offset)
            )
        }
        let zone = try XCTUnwrap(HRVReport.build(windows: windows, fitbitSamplesPerNight: 90).zone(.core))
        XCTAssertEqual(try XCTUnwrap(zone.nativeSpearman), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(zone.derivedSpearman), 1, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func tachogram(at start: Date, jitterMS: Double) -> Tachogram {
        var beats = [Heartbeat(timeSinceSeriesStart: 0, precededByGap: false)]
        var time = 0.0
        for step in 0..<20 {
            time += step.isMultiple(of: 2) ? 1.0 : 1.0 + jitterMS / 1000
            beats.append(Heartbeat(timeSinceSeriesStart: time, precededByGap: false))
        }
        return Tachogram(start: start, beats: beats)
    }
}
