import XCTest
import HealthKit
@testable import Airlift

/// Where Fitbit's HRV is filed: SDNN before iOS 27, RMSSD from it — and the
/// sync identifiers that keep the two from ever colliding.
final class HRVTypeTests: XCTestCase {
    func testHRVUsesRMSSDWhereTheTypeExists() {
        if let rmssd = MetricKind.rmssdIdentifier {
            XCTAssertEqual(MetricKind.heartRateVariability.hkIdentifier, rmssd)
        } else {
            XCTAssertEqual(MetricKind.heartRateVariability.hkIdentifier, MetricKind.legacyHRVIdentifier)
        }
    }

    func testLegacyHRVIsSDNN() {
        XCTAssertEqual(MetricKind.legacyHRVIdentifier, .heartRateVariabilitySDNN)
    }

    /// An RMSSD-typed copy must never share a sync identifier with its SDNN
    /// original, however HealthKit scopes them.
    func testRMSSDSyncIdentifiersAreDistinctFromLegacyOnes() {
        let id = HealthKitWriter.syncIdentifier(kind: .heartRateVariability, dataPointID: "p1")
        if MetricKind.rmssdIdentifier != nil {
            XCTAssertEqual(id, "airlift-heart_rate_variability-rmssd-p1")
        } else {
            XCTAssertEqual(id, "airlift-heart_rate_variability-p1")
        }
    }

    func testOtherKindsKeepTheirSyncIdentifiers() {
        XCTAssertEqual(
            HealthKitWriter.syncIdentifier(kind: .heartRate, dataPointID: "p1"),
            "airlift-heart_rate-p1"
        )
    }

    /// The caveat follows what Apple's side actually is that night, not the OS:
    /// an Ultra 2 night on iOS 27 is still SDNN.
    func testTheComparisonCaveatNamesTheStatistics() throws {
        let hrv = MetricKind.heartRateVariability
        XCTAssertTrue(try XCTUnwrap(hrv.appleComparisonCaveat(appleIsRMSSD: true)).contains("Watch RMSSD"))
        XCTAssertTrue(try XCTUnwrap(hrv.appleComparisonCaveat(appleIsRMSSD: false)).contains("Apple SDNN"))
        XCTAssertNil(MetricKind.heartRate.appleComparisonCaveat(appleIsRMSSD: false))
    }
}
