import AppKit
import CoreGraphics

/// Permission state for the exact bundle that is currently running.
///
/// macOS can display an enabled SideScreen row while Core Graphics rejects a
/// rebuilt or duplicate bundle. Keeping the bundle identity with the boolean
/// makes that mismatch visible instead of presenting a generic "Required"
/// status with no recovery context.
struct ScreenRecordingPermissionSnapshot: Equatable {
    let isGranted: Bool
    let bundleIdentifier: String
    let bundleName: String
    let bundlePath: String
    let canonicalInstallPath: String

    static func current(preflight: Bool = CGPreflightScreenCaptureAccess()) -> Self {
        let bundle = Bundle.main
        let bundlePath = bundle.bundlePath
        let canonicalPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/TabletBridge.app")
            .path

        return Self(
            isGranted: preflight,
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            bundleName: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "Tablet Bridge",
            bundlePath: bundlePath,
            canonicalInstallPath: canonicalPath
        )
    }

    static func initial() -> Self {
        current(preflight: false)
    }

    var isCanonicalInstall: Bool {
        normalizedPath(bundlePath) == normalizedPath(canonicalInstallPath)
    }

    var statusText: String {
        isGranted ? "Granted for this build" : "Required for this build"
    }

    var diagnosticText: String {
        if isGranted {
            return "macOS accepted Screen Recording for this exact running bundle."
        }
        return "macOS did not authorize this exact running bundle. The Settings switch may belong to another Tablet Bridge copy or an older local rebuild."
    }

    var recoveryText: String {
        if isCanonicalInstall {
            return "Turn Tablet Bridge off and on in Screen & System Audio Recording. If it remains Required, remove the entry and add this exact bundle again."
        }
        return "Launch the canonical installed copy before changing the permission. This process is not running from the expected local install path."
    }

    var identityText: String {
        "bundle=\(bundleIdentifier)\npath=\(bundlePath)"
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
