import XCTest
@testable import SideScreen

final class WirelessSessionProfileTests: XCTestCase {
    func testWirelessFrameRateIsHardCapped() {
        XCTAssertEqual(WirelessSessionProfile.frameRate(for: .wireless, requested: 120), 60)
        XCTAssertEqual(WirelessSessionProfile.frameRate(for: .wireless, requested: 30), 60)
    }

    func testUSBKeepsRequestedFrameRate() {
        XCTAssertEqual(WirelessSessionProfile.frameRate(for: .usb, requested: 120), 120)
    }

    func testWirelessBitrateProfileIsBounded() {
        XCTAssertEqual(WirelessSessionProfile.bitrateCap(for: .wireless), 40)
        XCTAssertEqual(WirelessSessionProfile.peakBitrateMbps, 60)
        XCTAssertNil(WirelessSessionProfile.bitrateCap(for: .usb))
    }
}
