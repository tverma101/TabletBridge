import Cocoa
import CoreGraphics

/// Native F1/F2 brightness for the SideScreen virtual display — no
/// BetterDisplay required.
///
/// HID: NX_KEYTYPE_BRIGHTNESS_DOWN (3) / BRIGHTNESS_UP (2) on the
/// NSSystemDefined / NX_SYSDEFINED (subtype 8) event. Virtual displays
/// have no IODisplay brightness endpoint, so macOS routes the key to the
/// built-in panel only. This controller intercepts the key, maintains a
/// virtual backlight (0..255, persisted), and forwards every step to the
/// tablet via `StreamingServer.sendBrightness` — same BRIGHT wire as the
/// BetterDisplay poller, but at <10 ms from HID, with a bezel HUD.
///
/// Activation: on by default; `defaults write dev.tabletbridge.host
/// SideScreen_brightnessKeys -bool false` to disable. The legacy
/// `SideScreen_exp_brightness` BetterDisplay poller remains and coexists
/// (both can send BRIGHT; last write wins on the tablet).
///
/// Requires Input Monitoring (CGEventTap on the HID tap when the app is
/// not key) or Accessibility otherwise — the existing permission prompt
/// covers it. Falls back to NSEvent monitors when the tap cannot be created,
/// so standard F1/F2 key events still work while SideScreen is key and, when
/// macOS permits global monitoring, while another app is focused.
final class NativeBrightnessController {
    static let defaultsKey = "SideScreen_virtualBrightness"
    private static let disableKey = "SideScreen_brightnessKeys"
    static let maximumLevel: Int = 255
    static let minimumLevel: Int = 8      // never black out the panel
    private static let coarseStep: Int = 16   // ~6% = macOS 16-stop scale
    private static let fineStep: Int = 4      // Option+Shift = 1/4 step

    var onBrightness: ((UInt8) -> Void)?

    private var _currentLevel: Int = 255
    private var currentLevel: Int {
        get { _currentLevel }
        set {
            _currentLevel = newValue
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            hud.show(level: newValue, max: Self.maximumLevel)
        }
    }
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localKeyboardMonitor: Any?
    private var globalKeyboardMonitor: Any?

    // Key codes used when the keyboard is configured to send ordinary F1/F2
    // events instead of the consumer-key brightness events.
    private static let standardBrightnessDownKeyCode: UInt16 = 122 // F1
    private static let standardBrightnessUpKeyCode: UInt16 = 120   // F2

    /// Set if we consumed the HID so AppKit must not also deliver it. The
    /// CGEventTap callback runs before the NSEvent monitor; without this the
    /// BezelServices bezel and our HUD would double-fire per press.
    private var suppressNextSystemDefined = false
    /// Avoids consuming the key-up of a key-down we already consumed.
    private var suppressKeyUpUntil: UInt64 = 0

    private let hud = BrightnessHUD()

    var level: UInt8 { UInt8(currentLevel) }

    var normalizedValue: Double {
        Self.normalizedValue(for: level)
    }

    init() {
        currentLevel = Self.persistedLevel
        debugLog("NativeBrightness: level \(currentLevel)/\(Self.maximumLevel)")
    }

    static var persistedLevel: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.defaultsKey) != nil else {
            return Self.maximumLevel
        }

        // integer(forKey:) returns 0 when absent. A real zero is not persisted
        // by this controller because the minimum keeps the panel recoverable.
        let saved = defaults.integer(forKey: Self.defaultsKey)
        return clampedLevel(saved == 0 ? Self.maximumLevel : saved)
    }

    static func clampedLevel(_ rawLevel: Int) -> Int {
        max(Self.minimumLevel, min(Self.maximumLevel, rawLevel))
    }

    static func normalizedValue(for level: UInt8) -> Double {
        Double(Int(level)) / Double(Self.maximumLevel)
    }

    static func level(forNormalizedValue value: Double) -> UInt8 {
        let raw = Int((value * Double(Self.maximumLevel)).rounded())
        return UInt8(clampedLevel(raw))
    }

    func start() {
        // Default ON. Only `defaults write ... SideScreen_brightnessKeys -bool false` disables.
        if let v = UserDefaults.standard.object(forKey: Self.disableKey) as? Bool, !v {
            debugLog("NativeBrightness: disabled via \(Self.disableKey)=false")
            return
        }
        installTapOrFallback()
        debugLog("NativeBrightness: started (level \(currentLevel))")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localKeyboardMonitor {
            NSEvent.removeMonitor(m)
            localKeyboardMonitor = nil
        }
        if let m = globalKeyboardMonitor {
            NSEvent.removeMonitor(m)
            globalKeyboardMonitor = nil
        }
        hud.hide()
        debugLog("NativeBrightness: stopped")
    }

    /// Apply a native macOS Settings/menu control value and send it through
    /// the same callback used by F1/F2. The persisted value is updated even
    /// while no tablet is connected; the next connection receives it through
    /// `pushCurrent()`.
    @discardableResult
    func setLevel(_ level: UInt8) -> UInt8 {
        let value = Self.clampedLevel(Int(level))
        guard value != currentLevel else { return UInt8(value) }
        currentLevel = value
        onBrightness?(UInt8(value))
        debugLog("NativeBrightness: control -> \(value)")
        return UInt8(value)
    }

    @discardableResult
    func setNormalizedValue(_ value: Double) -> UInt8 {
        setLevel(Self.level(forNormalizedValue: value))
    }

    /// Apply a level from the BetterDisplay poller or Settings so the HID
    /// steps remain contiguous (no jump on first F1/F2 after a slider drag).
    @discardableResult
    func syncExternalLevel(_ level: UInt8) -> UInt8 {
        let v = Self.clampedLevel(Int(level))
        guard v != currentLevel else { return UInt8(v) }
        currentLevel = v
        debugLog("NativeBrightness: sync external \(v)")
        return UInt8(v)
    }

    /// Force the tablet to our level (e.g. right after connect, before any
    /// key press, so the panel matches the persisted value).
    func pushCurrent() {
        onBrightness?(UInt8(currentLevel))
    }

    // MARK: — Event tap

    private func installTapOrFallback() {
        // CGEventTap on the HID tap sees brightness keys even when we are
        // not key — but requires Input Monitoring. Fall back to an
        // NSEvent global monitor (key-window scope) if creation fails.
        // NX_SYSDEFINED = 14 (brightness keys); CGEventType has no
        // .systemDefined case — use the raw numeric value.
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let ctrl = Unmanaged<NativeBrightnessController>.fromOpaque(refcon).takeUnretainedValue()
                return ctrl.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            debugLog("NativeBrightness: CGEventTap unavailable — using NSEvent fallback")
            installGlobalMonitor()
            installFunctionKeyMonitors()
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Also install the AppKit monitor so taps that are filtered by
        // Secure Input still arrive when we are key.
        installGlobalMonitor()
        installFunctionKeyMonitors()
    }

    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemDefined(event)
        }
    }

    private func installFunctionKeyMonitors() {
        guard localKeyboardMonitor == nil, globalKeyboardMonitor == nil else { return }

        // A local monitor can consume ordinary F1/F2 events when SideScreen's
        // Settings window is active. The global monitor covers the same key
        // path when the app is not key; the HID tap consumes it when available.
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleStandardFunctionKey(event) else { return event }
            return nil
        }
        globalKeyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleStandardFunctionKey(event)
        }
        debugLog("NativeBrightness: F1/F2 keyboard monitors installed")
    }

    // MARK: — CGEventTap path

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            debugLog("NativeBrightness: tap re-enabled after \(type)")
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            guard let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            return handleStandardFunctionKey(ns)
                ? nil
                : Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14 else { return Unmanaged.passUnretained(event) }
        guard let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        guard ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = (data1 & 0x0000FFFF)
        let keyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let keyUp = ((keyFlags & 0xFF00) >> 8) == 0x0B

        // NX_KEYTYPE: BRIGHTNESS_DOWN=3, BRIGHTNESS_UP=2; ILLUMINATION 21/22/23
        // are keyboard backlight — ignore. Legacy F1/F2 Fn-brightness boards
        // alias through the same 2/3 values at the HID system-defined layer.
        let isBrightness = keyCode == 2 || keyCode == 3
        guard isBrightness else { return Unmanaged.passUnretained(event) }

        // Pair the key-up with its key-down so the system bezel does not
        // re-appear on release.
        let now = DispatchTime.now().uptimeNanoseconds
        if keyUp {
            if now < suppressKeyUpUntil {
                suppressNextSystemDefined = true
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard keyDown else { return Unmanaged.passUnretained(event) }

        let isDown = (keyCode == 3)
        let fine = isFineStepHeld()
        let changed = step(isDown: isDown, fine: fine)
        if changed {
            onBrightness?(UInt8(currentLevel))
            suppressNextSystemDefined = true
            suppressKeyUpUntil = now + 600_000_000
            debugLog("NativeBrightness: CG tap \(isDown ? "DOWN" : "UP")\(fine ? " fine" : "") -> \(currentLevel)")
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: — NSEvent fallback path

    private func handleSystemDefined(_ event: NSEvent) {
        if suppressNextSystemDefined {
            suppressNextSystemDefined = false
            return
        }
        guard event.subtype.rawValue == 8 else { return }
        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = (data1 & 0x0000FFFF)
        let keyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        guard keyDown else { return }
        let isDownKey = keyCode == 3
        let isUpKey = keyCode == 2
        guard isDownKey || isUpKey else { return }
        let fine = isFineStepHeld()
        let changed = step(isDown: isDownKey, fine: fine)
        if changed {
            onBrightness?(UInt8(currentLevel))
            debugLog("NativeBrightness: NSEvent \(isDownKey ? "DOWN" : "UP")\(fine ? " fine" : "") -> \(currentLevel)")
        }
    }

    /// Handle F1/F2 when macOS is configured to deliver them as ordinary
    /// keyboard events instead of NX_KEYTYPE_BRIGHTNESS_* consumer events.
    /// Returns true when the event was consumed by the controller.
    private func handleStandardFunctionKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let isDownKey = event.keyCode == Self.standardBrightnessDownKeyCode
        let isUpKey = event.keyCode == Self.standardBrightnessUpKeyCode
        guard isDownKey || isUpKey else { return false }

        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control]
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: blockedModifiers) else {
            return false
        }

        let fine = isFineStepHeld(event.modifierFlags)
        let changed = step(isDown: isDownKey, fine: fine)
        guard changed else { return true }
        onBrightness?(UInt8(currentLevel))
        debugLog("NativeBrightness: F\(isDownKey ? 1 : 2)\(fine ? " fine" : "") -> \(currentLevel)")
        return true
    }

    private func isFineStepHeld(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        return flags.contains(.option) && flags.contains(.shift)
    }

    @discardableResult
    private func step(isDown: Bool, fine: Bool) -> Bool {
        let delta = fine ? Self.fineStep : Self.coarseStep
        let next = isDown ? max(Self.minimumLevel, currentLevel - delta)
                          : min(Self.maximumLevel, currentLevel + delta)
        guard next != currentLevel else { return false }
        currentLevel = next
        return true
    }
}

// MARK: — HUD

/// Borderless bezel-style OSD that mirrors the macOS brightness bezel.
/// Uses only AppKit (no BezelServices private API) so it is App Store
/// safe if that ever matters; the unsandboxed app could swap in
/// BSBrightnessChangedForDisplay later with no wire change.
private final class BrightnessHUD {
    private var panel: NSPanel?
    private var fillView: NSView?
    private var iconView: NSImageView?
    private var hideWork: DispatchWorkItem?

    func show(level: Int, max: Int) {
        DispatchQueue.main.async { [weak self] in self?.showOnMain(level: level, max: max) }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in self?.hideOnMain() }
    }

    private func showOnMain(level: Int, max: Int) {
        let frac = CGFloat(level) / CGFloat(max == 0 ? 255 : max)
        if panel == nil { buildPanel() }
        guard let panel, let fill = fillView else { return }
        let barW: CGFloat = 220
        // Animate by changing the fill width.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            fill.animator().frame = NSRect(x: 0, y: 0, width: barW * frac, height: 6)
        }
        iconView?.image = NSImage(systemSymbolName: level <= 8 ? "sun.min.fill" : level >= 250 ? "sun.max.fill" : "sun.max", accessibilityDescription: nil)
        iconView?.contentTintColor = .white
        if !panel.isVisible {
            centerPanel(panel)
            panel.orderFrontRegardless()
            // Also try the (private) system bezel so external displays get the
            // real OSD when available — best-effort, no hard dependency.
            postSystemBezelIfAvailable(fraction: frac)
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideOnMain() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func hideOnMain() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let w: CGFloat = 260
        let h: CGFloat = 88
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.worksWhenModal = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        container.layer?.borderWidth = 1

        let icon = NSImageView(frame: NSRect(x: 16, y: 30, width: 28, height: 28))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        container.addSubview(icon)
        iconView = icon

        let track = NSView(frame: NSRect(x: 56, y: 38, width: 220 - 16, height: 6))
        track.wantsLayer = true
        track.layer?.cornerRadius = 3
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        container.addSubview(track)

        let fill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 6))
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = NSColor.white.cgColor
        track.addSubview(fill)
        fillView = fill

        let label = NSTextField(labelWithString: "Brightness")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.frame = NSRect(x: 56, y: 14, width: 120, height: 14)
        container.addSubview(label)

        p.contentView = container
        panel = p
    }

    private func centerPanel(_ panel: NSPanel) {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let sf = screen.frame
            var pf = panel.frame
            pf.origin.x = sf.midX - pf.width / 2
            pf.origin.y = sf.midY + 140
            panel.setFrame(pf, display: false)
        }
    }

    /// Best-effort: ask BezelServices to show the real system bezel (brightness
    /// glyph + bar) in addition to our panel. No-ops on failure or when the
    /// framework is unavailable. Private API is acceptable for direct
    /// distribution (app is already unsandboxed + uses CGVirtualDisplay).
    private func postSystemBezelIfAvailable(fraction: CGFloat) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/BezelServices.framework/BezelServices", RTLD_NOW) else { return }
        defer { dlclose(handle) }
        typealias Fn = @convention(c) (UInt32, Float) -> Void
        // Symbol present on macOS 12..15; ignore if missing.
        guard let sym = dlsym(handle, "BSBrightnessChangedForDisplay") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // displayID 0 = main; value is 0..1.
        fn(0, Float(fraction))
    }
}
