import XCTest
@testable import SideScreen

final class ExperimentalDisplayProfileTests: XCTestCase {
    func testParsesSameAspectLogicalHiDPIExperiment() {
        XCTAssertEqual(
            ExperimentalDisplayProfile.parseLogicalSize("1280x801"),
            .init(width: 1280, height: 801)
        )
    }

    func testRejectsMalformedOrUnsafeOverride() {
        XCTAssertNil(ExperimentalDisplayProfile.parseLogicalSize("2560x1602x1"))
        XCTAssertNil(ExperimentalDisplayProfile.parseLogicalSize("320x200"))
        XCTAssertNil(ExperimentalDisplayProfile.parseLogicalSize("not-a-size"))
    }
}
