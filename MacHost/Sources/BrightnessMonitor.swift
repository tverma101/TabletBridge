import Foundation

/// BrightnessMonitor — translate BetterDisplay's software-brightness intent for
/// the Tablet Bridge virtual display into BRIGHT commands on the control channel.
///
/// BetterDisplay can only "fabricate" dimming for our virtual display (overlay/
/// color darkening of the streamed pixels). The tablet's OLED panel is the real
/// dimmer; the client applies BRIGHT (type 11) to its actual backlight. This
/// monitor reads the SAME per-display value BetterDisplay persists in
/// ~/Library/Preferences/pro.betterdisplay.BetterDisplay.plist:
///
///     value@softwareBrightness-OverlayController@Display:<N>   (0..1 float)
///
/// The live display is the one whose `name@Display:N` matches "TabletBridge" /
/// "BetterCast Display (Android (USB))" AND `connected@Display:N` is true.
/// Display IDs change when the sender restarts (new CGVirtualDisplay) — the
/// monitor re-scans on every plist change, so nothing needs configuring.
///
/// EFFICIENCY: stat-poll 1x/s; parse only when mtime changes (~5ms); the client
/// applies the backlight directly — zero per-frame cost, OLED power saved
/// (fabricated dimming darkens pixels at full backlight: no power saved, and
/// the encoder spends bits on darkening).
///
/// Gate: `defaults write dev.tabletbridge.host SideScreen_exp_brightness -bool true`
/// Default off — production behavior unchanged when unset.
final class BrightnessMonitor {
    var onBrightness: ((UInt8) -> Void)?

    private let prefsPath: String
    private let pollS: TimeInterval
    private let debounceS: TimeInterval
    private var lastMtime: TimeInterval?
    private var baselineTaken = false
    private var lastValue: Double?
    private var lastSentAt: TimeInterval = 0
    private var timer: Timer?
    private let displayNames: [String]

    init(
        prefsPath: String = NSHomeDirectory() + "/Library/Preferences/pro.betterdisplay.BetterDisplay.plist",
        pollS: TimeInterval = 1.0,
        debounceS: TimeInterval = 0.10,
        displayNames: [String] = ["TabletBridge", "BetterCast Display (Android (USB))"]
    ) {
        self.prefsPath = prefsPath
        self.pollS = pollS
        self.debounceS = debounceS
        self.displayNames = displayNames
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollS, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        debugLog("BrightnessMonitor: watching \(prefsPath) (poll \(pollS)s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: prefsPath),
              let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return }
        if lastMtime == mt { return }
        lastMtime = mt
        guard let dict = parsePrefs() else { return }

        // Highest display id = most recent registration (sender restarts make
        // new IDs; stale entries stay behind with connected=false).
        let candidates = dict.filter { entry in
            guard let name = entry.value["name"] as? String,
                  let connected = entry.value["connected"] as? Bool
            else { return false }
            return connected && displayNames.contains(where: { name.contains($0) })
        }
        guard let did = candidates.keys.max() else { return }
        let value = candidates[did]?["value"] as? Double

        if !baselineTaken {
            baselineTaken = true
            if let v = value {
                lastValue = v
                debugLog(String(format: "BrightnessMonitor: Display:%@ baseline v=%.3f (armed)", did, v))
            } else {
                debugLog("BrightnessMonitor: Display:\(did) no value yet (armed)")
            }
            return
        }
        if let v = value, v != lastValue {
            lastValue = v
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSentAt >= debounceS {
                lastSentAt = now
                send(v, display: did)
            } else {
                // Coalesce slider drags: send the latest on the next tick.
                DispatchQueue.main.asyncAfter(deadline: .now() + (debounceS - (now - lastSentAt))) { [weak self] in
                    guard let self else { return }
                    self.lastSentAt = ProcessInfo.processInfo.systemUptime
                    self.send(v, display: did)
                }
            }
        } else if value == nil && lastValue != nil {
            debugLog("BrightnessMonitor: value key vanished (pruned by BetterDisplay) — re-arming")
            lastValue = nil
        }
    }

    private func send(_ v: Double, display: String) {
        let clamped = max(0.0, min(1.0, v))
        let level = UInt8((clamped * 255.0).rounded())
        debugLog(String(format: "BrightnessMonitor: Display:%@ v=%.3f -> BRIGHT %d", display, clamped, level))
        onBrightness?(level)
    }

    /// Parse the BetterDisplay prefs plist (binary or XML) into
    /// [displayId: ["name": String, "connected": Bool, "value": Double]].
    private func parsePrefs() -> [String: [String: Any]]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any]
        else { return nil }
        var out: [String: [String: Any]] = [:]
        for (key, raw) in root {
            let parts = key.split(separator: "@", maxSplits: 1)
            guard parts.count == 2, parts[1].hasPrefix("Display:") else { continue }
            let prop = String(parts[0])
            let did = String(parts[1].dropFirst("Display:".count))
            var entry = out[did] ?? [:]
            if prop == "name", let s = raw as? String {
                entry["name"] = s
            } else if prop == "connected", let b = raw as? Bool {
                entry["connected"] = b
            } else if prop.hasPrefix("value@softwareBrightness-"), let n = raw as? NSNumber {
                entry["value"] = n.doubleValue
            }
            out[did] = entry
        }
        return out
    }
}
