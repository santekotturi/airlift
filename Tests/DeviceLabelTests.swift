import XCTest
@testable import Airlift

final class DeviceLabelTests: XCTestCase {
    private func decodeSource(_ json: String) throws -> WireDataSource {
        try JSONDecoder().decode(WireDataSource.self, from: Data(json.utf8))
    }

    func testDisplayNameWins() throws {
        let source = try decodeSource(
            #"{"platform":"FITBIT","device":{"displayName":"Charge 6","formFactor":"FITNESS_BAND"}}"#
        )
        XCTAssertEqual(source.fitbitDeviceLabel, "Charge 6")
    }

    func testModelFallsBackWhenNoDisplayName() throws {
        let source = try decodeSource(#"{"platform":"FITBIT","device":{"model":"Air"}}"#)
        XCTAssertEqual(source.fitbitDeviceLabel, "Air")
    }

    func testFormFactorMapsToGenericLabel() throws {
        let band = try decodeSource(#"{"platform":"FITBIT","device":{"formFactor":"FITNESS_BAND"}}"#)
        XCTAssertEqual(band.fitbitDeviceLabel, DeviceLabel.genericBand)
        let watch = try decodeSource(#"{"platform":"FITBIT","device":{"formFactor":"SMARTWATCH"}}"#)
        XCTAssertEqual(watch.fitbitDeviceLabel, DeviceLabel.genericWatch)
    }

    func testEmptyDeviceYieldsNoLabel() throws {
        // What real 2026-06 payloads actually send.
        let source = try decodeSource(#"{"platform":"FITBIT","device":{}}"#)
        XCTAssertNil(source.fitbitDeviceLabel)
    }

    func testHealthKitMirrorYieldsNoLabel() throws {
        let source = try decodeSource(
            #"{"platform":"HEALTH_KIT","device":{"manufacturer":"Apple Inc.","formFactor":"PHONE"}}"#
        )
        XCTAssertNil(source.fitbitDeviceLabel)
    }

    func testMergePrefersExplicitOverGeneric() {
        XCTAssertEqual(DeviceLabel.merge(current: nil, candidate: "Charge 6"), "Charge 6")
        XCTAssertEqual(DeviceLabel.merge(current: DeviceLabel.genericBand, candidate: "Charge 6"), "Charge 6")
        XCTAssertEqual(DeviceLabel.merge(current: "Charge 6", candidate: DeviceLabel.genericBand), "Charge 6")
        XCTAssertEqual(DeviceLabel.merge(current: "Charge 6", candidate: nil), "Charge 6")
        XCTAssertEqual(DeviceLabel.merge(current: nil, candidate: nil), nil)
        // An explicit name never gets replaced by a different explicit name —
        // first detection sticks until the user overrides.
        XCTAssertEqual(DeviceLabel.merge(current: "Charge 6", candidate: "Sense 2"), "Charge 6")
    }
}
