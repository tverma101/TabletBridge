import CoreVideo
import CoreGraphics
import XCTest
@testable import SideScreen

final class AdaptiveRefreshControllerTests: XCTestCase {
    func testPointerWakeIsScopedToCapturedDisplayBounds() {
        let bounds = CGRect(x: -1400, y: 204, width: 1400, height: 876)

        XCTAssertTrue(
            AdaptiveRefreshController.isPointerInsideCapturedDisplay(
                CGPoint(x: -700, y: 600),
                displayBounds: bounds
            )
        )
        XCTAssertFalse(
            AdaptiveRefreshController.isPointerInsideCapturedDisplay(
                CGPoint(x: 300, y: 600),
                displayBounds: bounds
            )
        )
        XCTAssertFalse(
            AdaptiveRefreshController.isPointerInsideCapturedDisplay(
                CGPoint(x: -700, y: 600),
                displayBounds: nil
            )
        )
    }

    func testCapturePixelFormatCanSelectVideoRangeForQualityAB() {
        let defaults = UserDefaults(suiteName: "AdaptiveRefreshControllerTests")!
        defaults.removePersistentDomain(forName: "AdaptiveRefreshControllerTests")
        defer { defaults.removePersistentDomain(forName: "AdaptiveRefreshControllerTests") }

        defaults.set("8bitVideo", forKey: "SideScreen_exp_pixelFormat")
        XCTAssertEqual(
            AdaptiveRefreshController.configuredPixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        defaults.set("10bit", forKey: "SideScreen_exp_pixelFormat")
        XCTAssertEqual(
            AdaptiveRefreshController.configuredPixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )

        defaults.removeObject(forKey: "SideScreen_exp_pixelFormat")
        XCTAssertEqual(
            AdaptiveRefreshController.configuredPixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        defaults.set("8bit", forKey: "SideScreen_exp_pixelFormat")
        XCTAssertEqual(
            AdaptiveRefreshController.configuredPixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
    }

    func testPatternInjectorMapsVideoRangeEndpoints() {
        let black = PatternInjector.ycbcr(0, 0, 0, fullRange: false)
        XCTAssertEqual(black.0, 16)
        XCTAssertEqual(black.1, 128)
        XCTAssertEqual(black.2, 128)

        let white = PatternInjector.ycbcr(255, 255, 255, fullRange: false)
        XCTAssertEqual(white.0, 235)
        XCTAssertEqual(white.1, 128)
        XCTAssertEqual(white.2, 128)
    }
}
