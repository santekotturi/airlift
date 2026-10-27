import XCTest
@testable import Airlift

/// Fitbit's published nightly HRV, from `daily-heart-rate-variability`.
/// Payload shape copied from a real 2026-06 response, values made up.
final class FitbitDailyHRVTests: XCTestCase {
    private let json = """
    {"dataPoints":[
      {"dataSource":{"recordingMethod":"PASSIVELY_MEASURED","device":{"manufacturer":"Apple Inc."},"platform":"HEALTH_KIT"},
       "dailyHeartRateVariability":{"date":{"year":2026,"month":1,"day":15},"averageHeartRateVariabilityMilliseconds":71.2,"deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds":0}},
      {"dataSource":{"recordingMethod":"DERIVED","device":{},"platform":"FITBIT"},
       "dailyHeartRateVariability":{"date":{"year":2026,"month":1,"day":15},"averageHeartRateVariabilityMilliseconds":48.3,"nonRemHeartRateBeatsPerMinute":"58","entropy":2.9,"deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds":50.4}},
      {"dataSource":{"recordingMethod":"DERIVED","device":{},"platform":"FITBIT"},
       "dailyHeartRateVariability":{"date":{"year":2026,"month":1,"day":4},"averageHeartRateVariabilityMilliseconds":44.0,"deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds":0}}
    ],"nextPageToken":"abc"}
    """

    private func decode() throws -> QuantityDataPointsResponse {
        try JSONDecoder.googleHealth.decode(QuantityDataPointsResponse.self, from: Data(json.utf8))
    }

    func testKeepsOnlyFitbitsOwnPoints() throws {
        let values = try decode().fitbitDailyHRV()
        XCTAssertEqual(values.map(\.day), ["2026-01-15", "2026-01-04"])
        XCTAssertEqual(values[0].average, 48.3)
        XCTAssertEqual(values[0].nonREMHeartRate, 58)
        XCTAssertEqual(values[0].deepSleepRMSSD, 50.4)
    }

    func testZeroDeepSleepMeansNotMeasured() throws {
        XCTAssertNil(try decode().fitbitDailyHRV()[1].deepSleepRMSSD)
    }

    func testOldestDateIsTheEarliestDayOnThePage() throws {
        let oldest = try XCTUnwrap(try decode().oldestDailyDate)
        XCTAssertEqual(CivilDay.string(from: oldest), "2026-01-04")
    }

    func testStoreLooksUpByWakeDayAndLaterFetchesWin() throws {
        let store = FitbitDailyHRVStore(defaults: nil)
        store.merge(try decode().fitbitDailyHRV())
        let wake = try XCTUnwrap(CivilDay.date(from: "2026-01-15"))
        XCTAssertEqual(store.value(forWakeDay: wake)?.average, 48.3)
        store.merge([FitbitDailyHRV(day: "2026-01-15", average: 49.0, deepSleepRMSSD: nil, nonREMHeartRate: nil)])
        XCTAssertEqual(store.value(forWakeDay: wake)?.average, 49.0)
    }
}
