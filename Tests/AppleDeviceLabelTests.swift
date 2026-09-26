import XCTest
@testable import Airlift

/// Naming the Apple device behind a sample, as the compare screen shows it.
final class AppleDeviceLabelTests: XCTestCase {
    func testKnownHardwareIsNamedByModel() {
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch7,5", sourceName: "Sante’s Apple Watch"), "Watch Ultra 2")
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch8,1", sourceName: nil), "Watch Ultra 4")
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch7,12", sourceName: nil), "Watch Ultra 3")
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch6,18", sourceName: nil), "Watch Ultra")
    }

    func testSeriesVariantsCollapseToOneName() {
        for id in ["Watch7,1", "Watch7,2", "Watch7,3", "Watch7,4"] {
            XCTAssertEqual(DeviceLabel.apple(hardware: id, sourceName: nil), "Watch Series 9")
        }
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch8,5", sourceName: nil), "Watch Series 12")
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch3,3", sourceName: nil), "Watch Series 3")
    }

    func testSEGenerationsAreTellable() {
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch5,9", sourceName: nil), "Watch SE")
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch6,12", sourceName: nil), "Watch SE (2nd generation)")
        XCTAssertEqual(DeviceLabel.apple(hardware: "Watch7,15", sourceName: nil), "Watch SE 3")
    }

    /// Hardware newer than the table: the source name, minus its owner.
    func testUnknownHardwareFallsBackToTheSourceName() {
        XCTAssertEqual(
            DeviceLabel.apple(hardware: "Watch9,1", sourceName: "Sante’s Apple\u{00A0}Watch Ultra 5"),
            "Watch Ultra 5"
        )
        XCTAssertEqual(DeviceLabel.apple(hardware: nil, sourceName: "Alex's iPhone"), "iPhone")
        XCTAssertEqual(DeviceLabel.apple(hardware: nil, sourceName: "Sante’s Apple Watch"), "Apple Watch")
        XCTAssertNil(DeviceLabel.apple(hardware: nil, sourceName: nil))
    }
}
