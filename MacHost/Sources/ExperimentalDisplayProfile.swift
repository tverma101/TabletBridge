import Foundation

/// Reversible, private display-size override for quality experiments.
///
/// The value is a logical HiDPI size. With SideScreen_hiDPI=1, 1280x801
/// produces a 2560x1602 physical source, which is almost exactly the Tab S8+
/// panel aspect ratio while giving Android the opportunity to do the final
/// upscale. An absent or invalid value preserves the normal settings profile.
enum ExperimentalDisplayProfile {
    static let logicalResolutionKey = "SideScreen_exp_sourceResolution"

    struct LogicalSize: Equatable {
        let width: Int
        let height: Int
    }

    static func logicalSize(
        fallback: LogicalSize,
        defaults: UserDefaults = .standard
    ) -> LogicalSize {
        guard let raw = defaults.string(forKey: logicalResolutionKey),
              let parsed = parseLogicalSize(raw) else {
            return fallback
        }
        return parsed
    }

    static func parseLogicalSize(_ raw: String) -> LogicalSize? {
        let parts = raw.lowercased().split(separator: "x", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width >= 640, width <= 7680,
              height >= 480, height <= 4320 else {
            return nil
        }
        return LogicalSize(width: width, height: height)
    }
}
