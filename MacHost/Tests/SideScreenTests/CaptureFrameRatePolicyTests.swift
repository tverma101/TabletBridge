import XCTest
@testable import SideScreen

final class CaptureFrameRatePolicyTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CaptureFrameRatePolicyTests")!
        defaults.removePersistentDomain(forName: "CaptureFrameRatePolicyTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "CaptureFrameRatePolicyTests")
        defaults = nil
        super.tearDown()
    }

    func testMain10CapsDisplayAndCaptureToSixty() {
        defaults.set("10bit", forKey: "SideScreen_exp_pixelFormat")

        XCTAssertEqual(
            CaptureFrameRatePolicy.effectiveFrameRate(requested: 120, defaults: defaults),
            60
        )
    }

    func testEightBitRetainsRequestedCeiling() {
        XCTAssertEqual(
            CaptureFrameRatePolicy.effectiveFrameRate(requested: 120, defaults: defaults),
            120
        )
    }

    func testExperimentFPSAppliesBeforeMain10SafetyCap() {
        defaults.set(90, forKey: "SideScreen_exp_fps")
        defaults.set("main10", forKey: "SideScreen_exp_profile")

        XCTAssertEqual(
            CaptureFrameRatePolicy.effectiveFrameRate(requested: 120, defaults: defaults),
            60
        )

        defaults.set(45, forKey: "SideScreen_exp_fps")
        XCTAssertEqual(
            CaptureFrameRatePolicy.effectiveFrameRate(requested: 120, defaults: defaults),
            45
        )
    }
}
