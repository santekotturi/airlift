import XCTest
import HealthKit
@testable import Airlift

/// Where Fitbit's HRV is filed: SDNN before iOS 27, RMSSD from it — and the
/// sync identifiers that keep the two from ever colliding.
final class HRVTypeTests: XCTestCase {
    func testHRVUsesRMSSDWhereTheTypeExists() {
        if #available(iOS 27.0, *) {
            XCTAssertEqual(MetricKind.heartRateVariability.hkIdentifier, .heartRateVariabilityRMSSD)
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
        if #available(iOS 27.0, *) {
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

    func testTheComparisonCaveatNamesTheStatistics() throws {
        let caveat = try XCTUnwrap(MetricKind.heartRateVariability.appleComparisonCaveat)
        if #available(iOS 27.0, *) {
            XCTAssertTrue(caveat.contains("Watch RMSSD"))
        } else {
            XCTAssertTrue(caveat.contains("Apple SDNN"))
        }
        XCTAssertNil(MetricKind.heartRate.appleComparisonCaveat)
    }
}
