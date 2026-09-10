import Foundation
import SystemConfiguration

enum StatusDetector {
    static func adbInstalled() -> Bool {
        adbExecutablePath() != nil
    }

    static func wifiReachable() -> Bool {
        guard let reach = SCNetworkReachabilityCreateWithName(nil, "1.1.1.1") else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags) else { return false }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    /// Run `adb devices`, return list of device serials in `device` state.
    static func usbDevices() -> [String] {
        guard let adbPath = adbExecutablePath(),
              let output = runProcess(adbPath, arguments: ["devices"]) else {
            return []
        }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
    }

    /// Parse one short-lived cached `adb reverse --list` snapshot. The status
    /// refresh asks about the video and control ports back-to-back; without the
    /// cache that spawned two identical adb subprocesses every refresh tick.
    static func adbReverseConfigured(port: Int) -> Bool {
        guard let output = adbReverseList() else { return false }
        return output.contains("tcp:\(port) tcp:\(port)")
    }

    private static let cacheLock = NSLock()
    private static var cachedAdbPath: String?
    private static var lastAdbCacheCheckUptime: TimeInterval = -.greatestFiniteMagnitude
    private static var cachedReverseList: String?
    private static var cachedReverseListAdbPath: String?
    private static var lastReverseListCheckUptime: TimeInterval = -.greatestFiniteMagnitude

    /// A valid adb executable does not need filesystem/PATH rediscovery every
    /// 10-second UI refresh. Cache successful resolution for a minute; misses
    /// remain short so installing platform-tools is still noticed quickly.
    private static func adbExecutablePath() -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        cacheLock.lock()
        let previous = cachedAdbPath
        let age = now - lastAdbCacheCheckUptime
        let ttl = previous == nil ? adbMissingCacheSeconds : adbFoundCacheSeconds
        if age >= 0, age < ttl {
            cacheLock.unlock()
            return previous
        }
        cacheLock.unlock()

        let candidatePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]

        var resolved: String?
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            resolved = path
            break
        }

        // Fallback: ask PATH only when adb is not in one of the standard
        // locations. This used to run every status refresh for PATH-only setups.
        if resolved == nil,
           let output = runProcess("/usr/bin/which", arguments: ["adb"]),
           !output.isEmpty {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                resolved = path
            }
        }

        cacheLock.lock()
        if cachedAdbPath != resolved {
            cachedReverseList = nil
            cachedReverseListAdbPath = nil
            lastReverseListCheckUptime = -.greatestFiniteMagnitude
        }
        cachedAdbPath = resolved
        lastAdbCacheCheckUptime = now
        cacheLock.unlock()
        return resolved
    }

    private static func adbReverseList() -> String? {
        guard let adbPath = adbExecutablePath() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime

        cacheLock.lock()
        if cachedReverseListAdbPath == adbPath,
           now - lastReverseListCheckUptime >= 0,
           now - lastReverseListCheckUptime < reverseListCacheSeconds {
            let cached = cachedReverseList
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let output = runProcess(adbPath, arguments: ["reverse", "--list"])

        cacheLock.lock()
        cachedReverseList = output
        cachedReverseListAdbPath = adbPath
        lastReverseListCheckUptime = now
        cacheLock.unlock()
        return output
    }

    private static func runProcess(_ executable: String, arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static let adbFoundCacheSeconds: TimeInterval = 60
    private static let adbMissingCacheSeconds: TimeInterval = 5
    private static let reverseListCacheSeconds: TimeInterval = 1
}
