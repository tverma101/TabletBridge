import XCTest
@testable import SideScreen

final class ScreenRecordingPermissionTests: XCTestCase {
    func testDeniedSnapshotIdentifiesCurrentBundleAndRecovery() {
        let snapshot = ScreenRecordingPermissionSnapshot(
            isGranted: false,
            bundleIdentifier: "dev.tabletbridge.host",
            bundleName: "Tablet Bridge",
            bundlePath: "/Users/test/Applications/TabletBridge.app",
            canonicalInstallPath: "/Users/test/Applications/TabletBridge.app"
        )

        XCTAssertEqual(snapshot.statusText, "Required for this build")
        XCTAssertTrue(snapshot.isCanonicalInstall)
        XCTAssertTrue(snapshot.diagnosticText.contains("exact running bundle"))
        XCTAssertTrue(snapshot.recoveryText.contains("remove the entry"))
        XCTAssertTrue(snapshot.identityText.contains("dev.tabletbridge.host"))
    }

    func testNonCanonicalSnapshotPointsAtCanonicalInstall() {
        let snapshot = ScreenRecordingPermissionSnapshot(
            isGranted: false,
            bundleIdentifier: "dev.tabletbridge.host",
            bundleName: "Tablet Bridge",
            bundlePath: "/tmp/TabletBridge.app",
            canonicalInstallPath: "/Users/test/Applications/TabletBridge.app"
        )

        XCTAssertFalse(snapshot.isCanonicalInstall)
        XCTAssertTrue(snapshot.recoveryText.contains("canonical installed copy"))
    }

    func testGrantedSnapshotUsesBuildSpecificStatus() {
        let snapshot = ScreenRecordingPermissionSnapshot(
            isGranted: true,
            bundleIdentifier: "dev.tabletbridge.host",
            bundleName: "Tablet Bridge",
            bundlePath: "/Users/test/Applications/TabletBridge.app",
            canonicalInstallPath: "/Users/test/Applications/TabletBridge.app"
        )

        XCTAssertEqual(snapshot.statusText, "Granted for this build")
        XCTAssertTrue(snapshot.diagnosticText.contains("accepted"))
    }
}
