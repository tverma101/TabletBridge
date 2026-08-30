import Foundation

/// Resolves the frame-rate ceiling shared by the virtual display,
/// ScreenCaptureKit, and VideoToolbox.
///
/// A virtual display that advertises a higher mode than the capture path can
/// consume still makes WindowServer do work at the higher cadence. Keep this
/// decision pure so the negotiated mode can be tested without creating a
/// display or starting ScreenCaptureKit.
enum CaptureFrameRatePolicy {
    static func effectiveFrameRate(
        requested: Int,
        defaults: UserDefaults = .standard
    ) -> Int {
        let experimentFPS = defaults.integer(forKey: "SideScreen_exp_fps")
        let configured = experimentFPS > 0 ? experimentFPS : requested
        let safeConfigured = max(1, configured)

        let pixelFormat = defaults.string(forKey: "SideScreen_exp_pixelFormat")
        let profile = defaults.string(forKey: "SideScreen_exp_profile")
        guard pixelFormat == "10bit" || profile == "main10" else {
            return safeConfigured
        }

        return min(safeConfigured, 60)
    }
}
