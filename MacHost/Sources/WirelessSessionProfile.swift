import Foundation

/// The bounded transport profile used for LAN/Wi-Fi sessions.
///
/// Wireless is deliberately a 60 FPS session even when the panel or the USB
/// profile is configured for 90/120 Hz. The encoder's existing 1.5x one-second
/// data-rate ceiling turns the 40 Mbps average target into an approximately
/// 60 Mbps peak, keeping Wi-Fi bursts bounded without making the display feel
/// slow during normal motion.
enum WirelessSessionProfile {
    static let frameRate = 60
    static let averageBitrateMbps = 40
    static let peakBitrateMbps = averageBitrateMbps * 3 / 2

    static func frameRate(for mode: ConnectionMode, requested: Int) -> Int {
        mode == .wireless ? frameRate : requested
    }

    static func bitrateCap(for mode: ConnectionMode) -> Int? {
        mode == .wireless ? averageBitrateMbps : nil
    }
}
