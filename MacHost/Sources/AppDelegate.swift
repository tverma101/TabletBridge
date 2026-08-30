import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os.log
@preconcurrency import ScreenCaptureKit

private final class AsyncDiagnosticWriter {
    private let queue = DispatchQueue(label: "diagnosticLog", qos: .utility)
    private let stateLock = NSLock()
    private let maxPendingWrites = 256
    private var pendingWrites = 0
    private var handle: FileHandle?

    func append(_ message: String) {
        stateLock.lock()
        guard pendingWrites < maxPendingWrites else {
            stateLock.unlock()
            return
        }
        pendingWrites += 1
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.pendingWrites = max(0, self.pendingWrites - 1)
                self.stateLock.unlock()
            }

            if self.handle == nil {
                let url = URL(fileURLWithPath: "/tmp/tabletbridge.log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self.handle = try? FileHandle(forWritingTo: url)
                _ = try? self.handle?.seekToEnd()
            }

            let line = String(format: "[%.3f] %@\n", Date().timeIntervalSince1970, message)
            if let data = line.data(using: .utf8) {
                try? self.handle?.write(contentsOf: data)
            }
        }
    }
}

private let diagnosticLogger = Logger(subsystem: "dev.tabletbridge.host", category: "runtime")
private let diagnosticWriter = AsyncDiagnosticWriter()

/// Unified logging is immediate and the legacy file is retained through a
/// bounded asynchronous writer. No control or touch packet performs file open,
/// seek, write, or close work inline.
func debugLog(_ message: String) {
    diagnosticLogger.log("\(message, privacy: .public)")
    diagnosticWriter.append(message)
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case pending          // Touch down, waiting to determine gesture
    case scrolling        // 1-finger scroll
    case longPressReady   // Long press detected, waiting for drag or release
    case dragging         // Long press + drag (left mouse drag)
    case twoFingerScroll  // 2-finger scroll
    case pinching         // Pinch zoom
}

struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000       // 250ms
    static let doubleTapMaxTime: UInt64 = 400_000_000  // 400ms
    static let doubleTapMaxDistance: CGFloat = 20
    static let longPressTime: UInt64 = 500_000_000     // 500ms
    static let scrollSensitivity: CGFloat = 1.2
    static let pinchMinDistance: CGFloat = 20
    static let minTouchInterval: UInt64 = 8_000_000    // ~120Hz
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Command-line diagnostic mode. A headless process may still run the
    /// server, but it must never present or activate the Settings window.
    private let headlessLaunch: Bool

    init(headlessLaunch: Bool = false) {
        self.headlessLaunch = headlessLaunch
        super.init()
    }

    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var brightnessMonitor: BrightnessMonitor?
    var nativeBrightness: NativeBrightnessController?
    var idleSleepMonitor: IdleSleepMonitor?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    let pairedDeviceStore = PairedDeviceStore()
    /// Name of the wireless device currently streaming (nil when no wireless client is active).
    /// Used to roll its `lastConnected` timestamp forward every status refresh tick so the UI
    /// shows "just now" while connected and freezes at the disconnect moment afterward.
    private var currentWirelessDevice: String?
    private var cancellables = Set<AnyCancellable>()
    private var statusRefreshTimer: Timer?
    /// Runtime performance values are diagnostic UI only. Publishing them on
    /// every one-second transport interval needlessly invalidates the whole
    /// SwiftUI settings tree while the stream is otherwise idle.
    private var lastPublishedStatsNs: UInt64 = 0
    /// Reentrancy latch for startServer() — a second Start (double-clicked menu
    /// item, auto-start racing a manual click) must not build a second virtual
    /// display / server. Main-actor confined.
    private var isStartingServer = false
    var isDaemonMode = false // Deprecated: keeping variable for ABI compatibility but unused

    /// Keep the bundle path visible in the diagnostic log. Screen Recording
    /// approval is identity-scoped on macOS; launching a second copy with the
    /// same display name can otherwise look like a permission regression.
    private func logRuntimeIdentity() {
        let bundle = Bundle.main
        debugLog(
            "Runtime identity: bundle=\(bundle.bundleIdentifier ?? "unknown") " +
                "path=\(bundle.bundlePath)"
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")
        logRuntimeIdentity()
        debugLog("Launch mode: \(headlessLaunch ? "headless" : "normal")")

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Setup settings observers
        setupSettingsObservers()

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Periodic status refresh for the per-mode checklist (ADB / WiFi / Listening IP).
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIndicators()
            }
        }
        // Initial refresh so the UI isn't blank for 2 seconds.
        Task { @MainActor in
            refreshStatusIndicators()
        }

        if headlessLaunch {
            debugLog("Headless launch: Settings window suppressed; app activation skipped")
        } else if #available(macOS 13.0, *) {
            if DaemonManager.shared.isEnabled {
                print("🚀 Launch at Login is enabled - starting silently in background")
                // Do not show settings window automatically.
                // applicationShouldHandleReopen will show it if the user manually launched the app.
            } else {
                showSettings()
            }
        } else {
            showSettings()
        }

        // Declarative auto-start (no Mac interaction): start the server in the
        // chosen Startup mode if enabled. No blocking permission modal here —
        // it cannot be acted on when the Mac is headless.
        if settings.autoStartStreamingOnLaunch {
            settings.connectionMode = settings.startupMode
            Task {
                // Preflight is diagnostic only. The actual capture setup below
                // is the authoritative test, so a stale TCC boolean cannot
                // prevent an explicitly configured auto-start from trying.
                await self.checkPermissions()
                await self.startServer()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from System Settings is the normal point at which a TCC
        // decision changes. Re-run the passive check for the exact bundle that
        // is now active instead of requiring a second launch or a manual Start
        // attempt to discover the new state.
        logRuntimeIdentity()
        Task { await checkPermissions() }
    }

    @MainActor
    private func refreshStatusIndicators() {
        // Keep the inline permission state current after the user returns from
        // System Settings, without generating another native prompt.
        refreshScreenRecordingPermission()
        settings.adbInstalled = StatusDetector.adbInstalled()
        settings.wifiConnected = StatusDetector.wifiReachable()
        settings.listeningAddress = LANAddressResolver.primaryIPv4()

        // While a wireless client is actively streaming, keep its lastConnected
        // rolling forward so the UI shows "just now". On disconnect, the
        // onClientDisconnected handler clears currentWirelessDevice — from that
        // point lastConnected stays frozen at the disconnect moment, so the
        // "X minutes ago" label counts up correctly.
        if let name = currentWirelessDevice {
            pairedDeviceStore.upsert(name: name, lastConnected: Date())
        }

        let port = Int(settings.port)
        let controlOverride = UserDefaults.standard.integer(forKey: "SideScreen_controlPort")
        let controlPort = controlOverride > 0 ? controlOverride : port + 1
        Task.detached { [weak self] in
            let devices = StatusDetector.usbDevices()
            let reverseOK = StatusDetector.adbReverseConfigured(port: port)
                && StatusDetector.adbReverseConfigured(port: controlPort)
            await MainActor.run { [weak self] in
                guard let self = self else { return }

                let isConnected = !devices.isEmpty

                self.settings.usbDeviceConnected = isConnected
                self.settings.adbReverseConfigured = reverseOK

                // Self-healing USB bridge (level-triggered, not edge-triggered):
                // whenever we are in USB mode with the server running and a
                // device present but adb reverse missing, (re)establish it.
                // Covers replug, adb-server restart, etc. The server lifecycle
                // is NOT tied to device events — it stays up and the tablet
                // reconnects via its own connect button.
                if self.settings.connectionMode == .usb
                    && isConnected
                    && self.settings.isRunning
                    && !reverseOK {
                    debugLog("🔌 USB bridge missing while running — (re)establishing adb reverse")
                    Task { await self.setupADBReverse() }
                }
            }
        }
    }

    @MainActor
    private func handleConnectionModeChange(to mode: ConnectionMode) async {
        debugLog("Connection mode changed to: \(mode.rawValue)")
        // Disconnect any active client immediately (per spec §6 / fix #2).
        let wasRunning = settings.isRunning
        if wasRunning {
            stopServer()
        }
        if mode == .wireless {
            // Generate token if missing; the QR will reflect it.
            _ = WirelessAuth.loadOrCreate()
        }
        if wasRunning {
            await startServer()
        }
    }

    /// Check permissions on demand (called when settings window opens or manually)
    func refreshPermissions() {
        Task {
            await checkPermissions()
        }
    }

    func setupSettingsObservers() {
        // Brightness is a persisted preference while disconnected and is
        // applied immediately through the controller when a session exists.
        settings.$brightness
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self, let controller = self.nativeBrightness else { return }
                controller.setNormalizedValue(value)
            }
            .store(in: &cancellables)

        // Observer cho gaming boost changes
        settings.$gamingBoost
            .dropFirst() // Skip initial value
            .sink { [weak self] gamingBoost in
                guard let self = self, self.settings.isRunning else { return }
                print("🎮 Gaming Boost \(gamingBoost ? "ENABLED" : "DISABLED")")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: self.settings.effectiveBitrate,
                    quality: self.settings.effectiveQuality,
                    gamingBoost: gamingBoost
                )
            }
            .store(in: &cancellables)

        // Observer cho bitrate/quality changes (chỉ khi không gaming boost)
        Publishers.CombineLatest(settings.$bitrate, settings.$quality)
            .dropFirst()
            .sink { [weak self] bitrate, quality in
                guard let self = self, self.settings.isRunning, !self.settings.gamingBoost else { return }
                print("⚙️ Settings updated: \(bitrate)Mbps, \(quality)")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: bitrate,
                    quality: quality,
                    gamingBoost: false
                )
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$rotation, settings.$flipHorizontal, settings.$flipVertical)
            .dropFirst()
            .sink { [weak self] rotation, flipHorizontal, flipVertical in
                guard let self = self, self.settings.isRunning else { return }
                print("🔄 Display transform changed: \(rotation)°, h=\(flipHorizontal), v=\(flipVertical)")
                self.streamingServer?.updateDisplayTransform(rotation: rotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
            }
            .store(in: &cancellables)

        // Observer cho touch enable/disable - propagate to streaming server so
        // incoming touch frames from the client are dropped early when off.
        settings.$touchEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.setTouchEnabledCache(enabled)
                self?.streamingServer?.touchEnabled = enabled
            }
            .store(in: &cancellables)

        // Observer cho connection mode changes — restart server with new auth/ADB policy.
        settings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleConnectionModeChange(to: mode)
                }
            }
            .store(in: &cancellables)

        // Observer cho resolution changes — the virtual display is created at
        // server start, so a new resolution (list row or custom Apply) needs a
        // stop/start cycle to take effect, same as a connection-mode change.
        // Without this, changing resolution mid-run silently did nothing.
        settings.$resolution
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] resolution in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.settings.isRunning else { return }
                    debugLog("Resolution changed to \(resolution) — restarting server to rebuild virtual display")
                    self.stopServer()
                    await self.startServer()
                }
            }
            .store(in: &cancellables)
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Tablet Bridge")
        }

        // Items are rebuilt on every open (menuNeedsUpdate) so the menu always
        // reflects live server/connection state.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu

        // Dim the menu bar icon while the server is stopped — at-a-glance
        // state without opening the menu.
        settings.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.statusItem?.button?.appearsDisabled = !running
            }
            .store(in: &cancellables)
    }

    @objc private func toggleServerFromMenu() {
        if settings.isRunning {
            stopServer()
        } else {
            Task { [weak self] in
                await self?.startServer()
            }
        }
    }

    @objc private func selectUSBMode() {
        guard settings.connectionMode != .usb else { return }
        settings.connectionMode = .usb
    }

    @objc private func selectWirelessMode() {
        guard settings.connectionMode != .wireless else { return }
        settings.connectionMode = .wireless
    }

    func setupSettingsWindow() {
        settingsWindow = SettingsWindowController(settings: settings)

        settings.onToggleServer = { [weak self] in
            guard let self else { return }
            if self.settings.isRunning {
                self.stopServer()
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    await self.checkPermissions()
                    await self.startServer()
                }
            }
        }

        settings.onRequestScreenRecordingPermission = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.requestScreenRecordingPermission()
            }
        }
        settings.onRefreshScreenRecordingPermission = { [weak self] in
            self?.refreshPermissions()
        }
        settings.onCopyScreenRecordingIdentity = { [weak self] in
            Task { @MainActor [weak self] in
                self?.copyScreenRecordingIdentity()
            }
        }
    }

    @objc func showSettings() {
        guard !headlessLaunch else {
            debugLog("Headless launch: ignored Settings presentation request")
            return
        }

        // Repeated lifecycle/error callbacks may ask for the same window. Do
        // not repeatedly steal focus when it is already visible and active.
        // Only the first presentation should activate the app. If the window
        // is already visible, a background permission/status/error callback
        // must not pull focus back from the user's current application.
        let shouldActivate = !(settingsWindow?.window?.isVisible ?? false)
        settingsWindow?.showWindow(nil)
        if shouldActivate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private func refreshScreenRecordingPermission() {
        let snapshot = ScreenRecordingPermissionSnapshot.current()
        let changed = settings.updateScreenRecordingPermission(snapshot)
        if changed {
            debugLog(
                "Screen Recording state: \(snapshot.statusText); " +
                    "bundle=\(snapshot.bundleIdentifier) path=\(snapshot.bundlePath)"
            )
        }
    }

    @MainActor
    private func copyScreenRecordingIdentity() {
        let snapshot = settings.screenRecordingPermission
        let text = "Tablet Bridge Screen Recording identity\n" +
            "status=\(snapshot.statusText)\n" +
            snapshot.identityText + "\n" +
            "canonical=\(snapshot.canonicalInstallPath)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        debugLog("Copied Screen Recording identity to the clipboard")
    }

    /// Refresh permission state without opening a system prompt. Screen capture
    /// permission is granted in System Settings; starting capture while the
    /// native prompt is unresolved makes ScreenCaptureKit fail and can stack a
    /// second app alert over the system dialog.
    func checkPermissions() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("checkPermissions — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        logRuntimeIdentity()

        await MainActor.run {
            refreshScreenRecordingPermission()
        }
        let hasScreenCapture = await MainActor.run { settings.hasScreenRecordingPermission }
        if hasScreenCapture {
            debugLog("Screen recording permission granted (CGPreflight)")
        } else {
            debugLog("Screen recording permission not granted for the current bundle")
        }

        // Check Accessibility permission (required for touch/mouse injection)
        await checkAccessibilityPermission()
    }

    /// Request access only after an explicit user action. This keeps launch
    /// non-blocking and, unlike the old force-start path, never starts capture
    /// while macOS is still resolving its native privacy prompt.
    @MainActor
    func requestScreenRecordingPermission() async {
        let coreGraphicsGranted = CGRequestScreenCaptureAccess()
        debugLog("CoreGraphics Screen Recording request completed: \(coreGraphicsGranted ? "granted" : "not granted")")
        // Do not start ScreenCaptureKit discovery here. On macOS 26 it can
        // race the privacy decision and create a second failure path before
        // the user has finished the System Settings action.
        refreshScreenRecordingPermission()
        if !settings.hasScreenRecordingPermission {
            showSettings()
        }
    }

    func checkAccessibilityPermission() async {
        let trusted = AXIsProcessTrusted()
        setAccessibilityCache(trusted)
        await MainActor.run {
            settings.hasAccessibilityPermission = trusted
        }
        if trusted {
            print("✅ Accessibility permission granted")
        } else {
            print("⚠️  Accessibility permission not granted - touch control will not work")
        }
    }

    @MainActor
    func promptAccessibilityPermission() {
        // This will show the system prompt to grant Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        setAccessibilityCache(trusted)
        settings.hasAccessibilityPermission = trusted

        if !trusted {
            print("⚠️  User needs to grant Accessibility permission in System Settings")
        }
    }

    /// Setup ADB reverse port forwarding for USB connection
    func setupADBReverse() async {
        let port = settings.port
        let controlOverride = UserDefaults.standard.integer(forKey: "SideScreen_controlPort")
        let controlPort = controlOverride > 0 ? UInt16(controlOverride) : port + 1
        let ports = [port, controlPort]
        print("🔌 Setting up ADB reverse for ports \(ports)...")
        debugLog("🔌 setupADBReverse() invoked for ports \(ports)...")

        await Task.detached(priority: .utility) {
            // Try common adb paths
            let adbPaths = [
                "/usr/local/bin/adb",
                "/opt/homebrew/bin/adb",
                "~/Library/Android/sdk/platform-tools/adb",
                "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
            ]

            var adbPath: String?
            for path in adbPaths {
                let expandedPath = NSString(string: path).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expandedPath) {
                    adbPath = expandedPath
                    break
                }
            }

            // Also try 'which adb' to find it in PATH
            if adbPath == nil {
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = ["adb"]
                let whichPipe = Pipe()
                whichProcess.standardOutput = whichPipe
                whichProcess.standardError = FileHandle.nullDevice

                do {
                    try whichProcess.run()
                    whichProcess.waitUntilExit()
                    let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        adbPath = path
                    }
                } catch {
                    // Ignore
                }
            }

            guard let finalAdbPath = adbPath else {
                print("⚠️  ADB not found - USB connection may not work")
                print("💡 Install Android SDK or run manually: adb reverse tcp:\(port) tcp:\(port)")
                return
            }

            print("📱 Found ADB at: \(finalAdbPath)")

            // Configure both bulk video and the dedicated control channel.
            // Retry each mapping up to 3 times so USB cannot be left in a
            // half-working state after an authorization delay.
            for reversePort in ports {
                var configured = false
                for attempt in 1...3 {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: finalAdbPath)
                    process.arguments = ["reverse", "tcp:\(reversePort)", "tcp:\(reversePort)"]

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe

                    do {
                        try process.run()
                        process.waitUntilExit()

                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? ""

                        if process.terminationStatus == 0 {
                            print("✅ ADB reverse setup successful: tcp:\(reversePort) -> tcp:\(reversePort)")
                            configured = true
                            break
                        }
                        print("⚠️  ADB reverse tcp:\(reversePort) attempt \(attempt)/3 failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    } catch {
                        print("⚠️  Failed to configure adb reverse tcp:\(reversePort) (attempt \(attempt)/3): \(error.localizedDescription)")
                    }

                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }

                if !configured {
                    print("💡 Make sure Android device is connected via USB with debugging enabled")
                    return
                }
            }
        }.value
    }

    func startServer() async {
        let canStart = await MainActor.run { () -> Bool in
            guard !isStartingServer, !settings.isRunning else { return false }
            isStartingServer = true
            return true
        }
        guard canStart else {
            debugLog("startServer() ignored — already starting or already running")
            return
        }
        defer {
            Task { @MainActor [weak self] in self?.isStartingServer = false }
        }
        await MainActor.run {
            refreshScreenRecordingPermission()
            settings.screenCaptureOperational = false
            settings.screenCaptureFailure = nil
            settings.captureMethod = "Starting..."
        }
        let hasScreenCapture = await MainActor.run { settings.hasScreenRecordingPermission }
        debugLog("🚀 startServer() invoked. Screen Recording preflight: \(hasScreenCapture) (advisory)")
        if !hasScreenCapture {
            debugLog("⚠️ Screen Recording preflight is negative; attempting actual capture setup anyway")
        }

        do {
            let isWirelessSession = settings.connectionMode == .wireless
            let requestedSessionFrameRate = WirelessSessionProfile.frameRate(
                for: settings.connectionMode,
                requested: settings.effectiveRefreshRate
            )
            let sessionFrameRate = CaptureFrameRatePolicy.effectiveFrameRate(
                requested: requestedSessionFrameRate
            )
            let sessionBitrateCap = WirelessSessionProfile.bitrateCap(for: settings.connectionMode)
            debugLog(
                "Session profile: mode=\(settings.connectionMode.rawValue) " +
                    "requestedFPS=\(requestedSessionFrameRate) effectiveFPS=\(sessionFrameRate)" +
                    (sessionBitrateCap.map { ", avgBitrateCap=\($0)Mbps, peak=\(WirelessSessionProfile.peakBitrateMbps)Mbps" } ?? "")
            )

            // Create virtual display and run ADB setup in parallel
            virtualDisplayManager = VirtualDisplayManager()
            let configuredSize = settings.resolutionSize
            let size = ExperimentalDisplayProfile.logicalSize(
                fallback: .init(width: configuredSize.width, height: configuredSize.height)
            )
            if size.width != configuredSize.width || size.height != configuredSize.height {
                debugLog(
                    "Experimental source resolution: logical \(size.width)x\(size.height) " +
                        "(HiDPI physical \(size.width * 2)x\(size.height * 2))"
                )
            }
            try virtualDisplayManager?.createDisplay(
                width: size.width,
                height: size.height,
                // Keep the actual display mode at the effective capture cap.
                // This matters for USB Main10 too: the encoder is stable at
                // 60 FPS, so advertising 120 Hz only makes WindowServer wake
                // for work the pipeline cannot use.
                refreshRate: sessionFrameRate,
                hiDPI: settings.hiDPI,
                name: "TabletBridge"
            )

            // Disable mirror mode (may fail if already in extend mode)
            do {
                try virtualDisplayManager?.disableMirrorMode()
            } catch {
                // Not critical - continue anyway
            }

            await MainActor.run {
                settings.displayCreated = true
            }

            // Run ADB setup (USB only) and display init wait in parallel.
            // For wireless mode, skip ADB entirely — the auth handshake gates LAN connections instead.
            await withTaskGroup(of: Void.self) { group in
                if settings.connectionMode == .usb {
                    group.addTask { await self.setupADBReverse() }
                } else {
                    debugLog("Wireless mode: skipping ADB setup")
                }
                group.addTask { try? await Task.sleep(nanoseconds: 500_000_000) }
            }

            virtualDisplayManager?.restoreDisplayPosition()

            // Verify display is registered in the system
            if let vdm = virtualDisplayManager {
                let registered = vdm.verifyDisplayRegistered()
                if !registered {
                    debugLog("WARNING: Virtual display not found in online display list — capture may fail")
                }
            }

            // Setup ScreenCaptureKit independently from the host listener.
            // TCC/preflight and SCShareableContent can be stale or unavailable;
            // neither should prevent the user from launching the host and
            // repairing the exact installed bundle's permission.
            var captureReady = false
            if let displayID = virtualDisplayManager?.displayID {
                do {
                    screenCapture = try await ScreenCapture()
                    screenCapture?.onCaptureMethodChanged = { [weak self] method in
                        guard let self = self else { return }
                        debugLog("Capture method: \(method)")
                        Task { @MainActor in
                            self.settings.captureMethod = method
                            let operational = !method.hasPrefix("Unavailable")
                            self.settings.screenCaptureOperational = operational
                            self.settings.screenCaptureFailure = operational ? nil : method
                        }
                    }
                    try await screenCapture?.setupForVirtualDisplay(
                        displayID,
                        refreshRate: sessionFrameRate,
                        frameRateCap: isWirelessSession ? WirelessSessionProfile.frameRate : nil
                    )
                    captureReady = true
                } catch {
                    let description = String(describing: error)
                    debugLog("ScreenCaptureKit setup unavailable; keeping host/listener available: \(description)")
                    await MainActor.run {
                        settings.captureMethod = "Unavailable — ScreenCaptureKit setup failed"
                        settings.screenCaptureOperational = false
                        settings.screenCaptureFailure = "ScreenCaptureKit setup failed: \(description)"
                    }
                }
            } else {
                let description = "Virtual display ID was not available"
                debugLog("ScreenCaptureKit setup unavailable; keeping host/listener available: \(description)")
                await MainActor.run {
                    settings.captureMethod = "Unavailable — \(description)"
                    settings.screenCaptureOperational = false
                    settings.screenCaptureFailure = description
                }
            }

            // Setup server. Control channel (out-of-band ping/pong + keyframe
            // requests) runs on its own port: settings.port + 1, overridable
            // via `defaults write dev.tabletbridge.host SideScreen_controlPort -int N`.
            let controlOverride = UserDefaults.standard.integer(forKey: "SideScreen_controlPort")
            let controlPort: UInt16 = controlOverride > 0 ? UInt16(controlOverride) : settings.port + 1
            streamingServer = StreamingServer(port: settings.port, controlPort: controlPort)
            setTouchEnabledCache(settings.touchEnabled)
            if let displayID = virtualDisplayManager?.displayID {
                setTouchDisplayBounds(CGDisplayBounds(displayID))
            }
            streamingServer?.touchEnabled = settings.touchEnabled
            if settings.connectionMode == .wireless {
                streamingServer?.expectedAuthToken = WirelessAuth.loadOrCreate()
                streamingServer?.onWirelessClientPaired = { [weak self] deviceName in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.currentWirelessDevice = deviceName
                        self.settings.currentWirelessDevice = deviceName
                        self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
                    }
                }
            }
            // Provisional size before codec negotiation. onCodecNegotiated below
            // replaces this with the exact encoded dimensions before the config is
            // sent, so Android configures MediaCodec and its render surface for the
            // pixels actually carried by the stream.
            streamingServer?.setDisplaySize(width: size.width, height: size.height, rotation: settings.rotation, flipHorizontal: settings.flipHorizontal, flipVertical: settings.flipVertical)
            streamingServer?.onClientConnected = { [weak self] in
                guard let self = self else { return }
                self.screenCapture?.requestKeyframeOrReplayCachedFrame(force: true)
                // Push the persisted/native level immediately so the panel
                // matches without requiring an F1/F2 press.
                self.nativeBrightness?.pushCurrent()
                Task { @MainActor in
                    self.settings.clientConnected = true
                }
            }
            // Runs synchronously on the server's network queue BEFORE the
            // display config is sent, so the config below carries the right
            // dimensions for the negotiated codec.
            streamingServer?.onCodecNegotiated = { [weak self] codec in
                guard let self = self, let capture = self.screenCapture else { return }
                capture.negotiate(codec: codec, clientLimit: self.streamingServer?.clientDecodeLimits)
                let enc = capture.encodeSize(for: codec)
                self.streamingServer?.setDisplaySize(width: enc.width, height: enc.height, rotation: self.settings.rotation, flipHorizontal: self.settings.flipHorizontal, flipVertical: self.settings.flipVertical)
            }
            streamingServer?.onKeyframeRequested = { [weak self] force in
                self?.screenCapture?.requestKeyframeOrReplayCachedFrame(force: force)
            }

            streamingServer?.onClientDisconnected = { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.settings.clientConnected = false
                    // Final lastConnected snapshot at the disconnect moment, then
                    // freeze (currentWirelessDevice = nil stops the rolling update
                    // in refreshStatusIndicators).
                    if let name = self.currentWirelessDevice {
                        self.pairedDeviceStore.upsert(name: name, lastConnected: Date())
                        self.currentWirelessDevice = nil
                        self.settings.currentWirelessDevice = nil
                    }
                }
            }

            streamingServer?.onTouchEvent = { [weak self] x, y, action, pointerCount, x2, y2, parsedAtNs in
                self?.enqueueTouch(
                    x: x,
                    y: y,
                    action: action,
                    pointerCount: pointerCount,
                    x2: x2,
                    y2: y2,
                    parsedAtNs: parsedAtNs
                )
            }

            streamingServer?.onStats = { [weak self] fps, mbps in
                let captured = self
                Task { @MainActor in
                    guard let captured,
                          captured.settingsWindow?.window?.isVisible == true else {
                        return
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard captured.lastPublishedStatsNs == 0 ||
                            now - captured.lastPublishedStatsNs >= 2_000_000_000 else {
                        return
                    }
                    captured.lastPublishedStatsNs = now
                    captured.settings.currentFPS = fps
                    captured.settings.currentBitrate = mbps
                }
            }

            // Native brightness: F1/F2 control the tablet's real backlight
            // directly (HID -> BRIGHT on the control channel) with a bezel
            // HUD. ON by default; `defaults write dev.tabletbridge.host
            // SideScreen_brightnessKeys -bool false` to disable.
            let nb = NativeBrightnessController()
            nb.onBrightness = { [weak self] level in
                self?.settings.updateBrightnessFromController(level)
                self?.streamingServer?.sendBrightness(level)
            }
            nb.start()
            nativeBrightness = nb
            settings.updateBrightnessFromController(nb.level)

            // BetterDisplay bridge (experiment-gated): translate BetterDisplay's
            // software-brightness intent for this virtual display into BRIGHT
            // as well. Coexists with the native controller; last write wins.
            // When both are active, BetterDisplay slider drags stay smooth by
            // syncing the native controller's level.
            if UserDefaults.standard.bool(forKey: "SideScreen_exp_brightness") {
                let monitor = BrightnessMonitor()
                monitor.onBrightness = { [weak self] level in
                    guard let self else { return }
                    let effectiveLevel = self.nativeBrightness?.syncExternalLevel(level) ?? level
                    self.settings.updateBrightnessFromController(effectiveLevel)
                    self.streamingServer?.sendBrightness(effectiveLevel)
                }
                monitor.start()
                brightnessMonitor = monitor
                debugLog("Brightness bridge ENABLED (SideScreen_exp_brightness) + native F1/F2")
            } else {
                debugLog("Brightness bridge disabled (knob unset) — native F1/F2 \(nb)")
            }

            // Idle sleep (experiment-gated): when no client is connected for
            // the grace window, pause capture+encode (CPU -> ~0). Resume is
            // instant: onClientConnected forces a keyframe/replays the cached
            // frame, and resumeFromIdle restarts the SCStream underneath.
            if UserDefaults.standard.bool(forKey: "SideScreen_exp_idleSleep") {
                let secs = UserDefaults.standard.integer(forKey: "SideScreen_exp_idleSleepSecs")
                let grace = secs > 0 ? Double(secs) : 15.0
                let monitor = IdleSleepMonitor(
                    isClientConnected: { [weak self] in self?.settings.clientConnected ?? false },
                    pause: { [weak self] in self?.screenCapture?.pauseForIdle() },
                    resume: { [weak self] in
                        self?.screenCapture?.resumeFromIdle()
                        self?.screenCapture?.requestKeyframeOrReplayCachedFrame(force: true)
                    },
                    graceSecs: grace
                )
                monitor.start()
                idleSleepMonitor = monitor
                debugLog("Idle-sleep monitor ENABLED (grace \(grace)s)")
            } else {
                debugLog("Idle-sleep monitor disabled (knob unset)")
            }

            streamingServer?.start()
            if captureReady {
                screenCapture?.startStreaming(
                    to: streamingServer,
                    bitrateMbps: settings.effectiveBitrate,
                    quality: settings.effectiveQuality,
                    gamingBoost: settings.gamingBoost,
                    frameRate: sessionFrameRate,
                    bitrateCapMbps: sessionBitrateCap,
                    frameRateCap: isWirelessSession ? WirelessSessionProfile.frameRate : nil
                )
            } else {
                debugLog("Server started without ScreenCaptureKit capture")
            }

            await MainActor.run {
                // The host is running even when capture is unavailable. The
                // capture status becomes operational only after SCStream
                // delivers its first frame.
                settings.isRunning = true
            }

            print("✅ Server started on port \(settings.port)")
        } catch {
            print("❌ Failed to start: \(error)")
            let errorDescription = error.localizedDescription
            let permissionDenied = errorDescription.localizedCaseInsensitiveContains("TCC")
                || errorDescription.localizedCaseInsensitiveContains("declined")
                || errorDescription.localizedCaseInsensitiveContains("not authorized")
            await MainActor.run {
                stopServer()

                if permissionDenied {
                    // TCC denial belongs in the existing inline permission card.
                    // Do not stack a blocking app alert over macOS's own prompt.
                    refreshScreenRecordingPermission()
                    showSettings()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Start Server"
                    alert.informativeText = errorDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    func stopServer() {
        // Save display position before destroying
        virtualDisplayManager?.saveDisplayPosition()

        idleSleepMonitor?.stop()
        idleSleepMonitor = nil
        nativeBrightness?.stop()
        nativeBrightness = nil
        brightnessMonitor?.stop()
        brightnessMonitor = nil

        screenCapture?.stopStreaming()
        streamingServer?.stop()
        virtualDisplayManager?.destroyDisplay()

        settings.isRunning = false
        settings.displayCreated = false
        settings.clientConnected = false
        settings.screenCaptureOperational = false
        settings.screenCaptureFailure = nil
        settings.currentFPS = 0
        settings.currentBitrate = 0
        lastPublishedStatsNs = 0
        settings.captureMethod = "Initializing..."
        setTouchDisplayBounds(nil)

        print("⏹️ Server stopped")
    }

    // MARK: - Gesture Properties

    private struct CachedTouchState {
        var enabled = true
        var accessibilityGranted = false
        var displayBounds: CGRect?
    }

    /// Parsed control packets land here without touching the main queue. All
    /// gesture state, timers, and CGEvent posting remain ordered on this queue.
    private let inputQueue = DispatchQueue(label: "inputQueue", qos: .userInteractive)
    private let touchStateLock = NSLock()
    private var cachedTouchState = CachedTouchState()
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var accessibilityWarningShown = false
    private var gestureState: GestureState = .idle
    private var lastTouchTime: UInt64 = 0
    private var handledTouchCount = 0
    private var lastHandledTouchNs: UInt64 = 0
    private var maxHandledTouchGapMs = 0.0

    // Touch tracking
    private var touchStartPosition: CGPoint = .zero
    private var touchLastPosition: CGPoint = .zero
    private var touchStartTime: UInt64 = 0
    private var touchLastMoveTime: UInt64 = 0
    private var lastScrollDeltaX: CGFloat = 0
    private var lastScrollDeltaY: CGFloat = 0

    // Double tap tracking
    private var lastTapTime: UInt64 = 0
    private var lastTapPosition: CGPoint = .zero

    // Long press timer
    private var longPressTimer: DispatchWorkItem?

    // 2-finger tracking
    private var initialPinchDistance: CGFloat = 0
    private var lastPinchDistance: CGFloat = 0

    // Momentum scrolling
    private var momentumTimer: DispatchSourceTimer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    private func setTouchEnabledCache(_ enabled: Bool) {
        touchStateLock.lock()
        cachedTouchState.enabled = enabled
        touchStateLock.unlock()
    }

    private func setAccessibilityCache(_ granted: Bool) {
        touchStateLock.lock()
        cachedTouchState.accessibilityGranted = granted
        touchStateLock.unlock()
    }

    private func setTouchDisplayBounds(_ bounds: CGRect?) {
        touchStateLock.lock()
        cachedTouchState.displayBounds = bounds
        touchStateLock.unlock()
    }

    private func readCachedTouchState() -> CachedTouchState {
        touchStateLock.lock()
        defer { touchStateLock.unlock() }
        return cachedTouchState
    }

    private func enqueueTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int,
        x2: Float,
        y2: Float,
        parsedAtNs: UInt64
    ) {
        inputQueue.async { [weak self] in
            self?.handleTouch(
                x: x,
                y: y,
                action: action,
                pointerCount: pointerCount,
                x2: x2,
                y2: y2,
                parsedAtNs: parsedAtNs
            )
        }
    }

    // MARK: - Touch Entry Point

    private func handleTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int = 1,
        x2: Float = 0,
        y2: Float = 0,
        parsedAtNs: UInt64 = 0
    ) {
        let cached = readCachedTouchState()
        guard cached.enabled else { return }

        let handledAt = DispatchTime.now().uptimeNanoseconds
        if action == 0 {
            handledTouchCount = 0
            lastHandledTouchNs = handledAt
            maxHandledTouchGapMs = 0
        } else if lastHandledTouchNs > 0 {
            let gapMs = Double(handledAt - lastHandledTouchNs) / 1_000_000.0
            maxHandledTouchGapMs = max(maxHandledTouchGapMs, gapMs)
            lastHandledTouchNs = handledAt
        }
        handledTouchCount += 1
        if handledTouchCount % 120 == 0 {
            let parseToQueueMs = parsedAtNs > 0 && handledAt >= parsedAtNs
                ? Double(handledAt - parsedAtNs) / 1_000_000.0
                : 0
            debugLog(
                String(
                    format: "TOUCH input queue: count=%d maxGap=%.2fms parse->queue=%.3fms",
                    handledTouchCount,
                    maxHandledTouchGapMs,
                    parseToQueueMs
                )
            )
            maxHandledTouchGapMs = 0
        }

        if !cached.accessibilityGranted {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility not granted - touch ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let bounds = cached.displayBounds else { return }

        let p1 = CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
        let p2 = CGPoint(
            x: bounds.origin.x + CGFloat(x2) * bounds.width,
            y: bounds.origin.y + CGFloat(y2) * bounds.height
        )

        if pointerCount >= 2 {
            handleTwoFingerTouch(p1: p1, p2: p2, action: action)
        } else {
            handleOneFingerTouch(at: p1, action: action)
        }

        let postedAt = DispatchTime.now().uptimeNanoseconds
        if parsedAtNs > 0, postedAt >= parsedAtNs, handledTouchCount % 120 == 0 {
            debugLog(
                String(
                    format: "TOUCH parsed->CGEvent path=%.3fms",
                    Double(postedAt - parsedAtNs) / 1_000_000.0
                )
            )
        }
    }

    // MARK: - 1-Finger Gesture State Machine

    private func handleOneFingerTouch(at point: CGPoint, action: Int) {
        switch action {
        case 0: oneFingerDown(at: point)
        case 1: oneFingerMove(to: point)
        case 2: oneFingerUp(at: point)
        default: break
        }
    }

    private func oneFingerDown(at point: CGPoint) {
        stopMomentumScroll()
        cancelLongPressTimer()

        touchStartPosition = point
        touchLastPosition = point
        touchStartTime = DispatchTime.now().uptimeNanoseconds
        touchLastMoveTime = touchStartTime
        gestureState = .pending

        // Move cursor to touch position (absolute)
        moveCursor(to: point)

        // Start long press timer
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.gestureState == .pending else { return }
            self.gestureState = .longPressReady
        }
        longPressTimer = timer
        inputQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(GestureThresholds.longPressTime)),
            execute: timer
        )
    }

    private func oneFingerMove(to point: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastTouchTime < GestureThresholds.minTouchInterval { return }
        lastTouchTime = now

        let deltaX = point.x - touchLastPosition.x
        let deltaY = point.y - touchLastPosition.y
        let totalDistance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            if totalDistance > GestureThresholds.tapMaxDistance {
                cancelLongPressTimer()
                gestureState = .scrolling
                let sx = deltaX * GestureThresholds.scrollSensitivity
                let sy = deltaY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .longPressReady:
            if totalDistance > GestureThresholds.tapMaxDistance {
                // Long press + drag → left mouse drag
                gestureState = .dragging
                injectMouseDown(at: touchStartPosition)
                injectMouseDragged(to: point)
            }

        case .scrolling:
            let sx = deltaX * GestureThresholds.scrollSensitivity
            let sy = deltaY * GestureThresholds.scrollSensitivity
            injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
            let timeDelta = now - touchLastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .dragging:
            injectMouseDragged(to: point)

        default:
            break
        }

        touchLastPosition = point
        touchLastMoveTime = now
    }

    private func oneFingerUp(at point: CGPoint) {
        cancelLongPressTimer()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - touchStartTime
        let distance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            // Quick release, no movement → tap or double tap
            if distance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime {
                // Check double tap
                let timeSinceLastTap = now - lastTapTime
                let distFromLastTap = hypot(point.x - lastTapPosition.x, point.y - lastTapPosition.y)

                if timeSinceLastTap < GestureThresholds.doubleTapMaxTime
                    && distFromLastTap < GestureThresholds.doubleTapMaxDistance {
                    performDoubleClick(at: point)
                    lastTapTime = 0  // Reset so triple tap doesn't trigger
                } else {
                    performClick(at: point)
                    lastTapTime = now
                    lastTapPosition = point
                }
            }

        case .longPressReady:
            // Held long but didn't drag → right click
            performRightClick(at: point)

        case .scrolling:
            // Check momentum
            let timeSinceLastMove = now - touchLastMoveTime
            if timeSinceLastMove < 50_000_000 {
                let threshold: CGFloat = 2.0
                if abs(lastScrollDeltaX) > threshold || abs(lastScrollDeltaY) > threshold {
                    startMomentumScroll(
                        velocityX: lastScrollDeltaX * 6.0,
                        velocityY: lastScrollDeltaY * 6.0,
                        at: point
                    )
                }
            }

        case .dragging:
            injectMouseUp(at: point)

        default:
            break
        }

        gestureState = .idle
    }

    // MARK: - 2-Finger Gestures

    private func handleTwoFingerTouch(p1: CGPoint, p2: CGPoint, action: Int) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        switch action {
        case 0: // Down
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle  // Reset so 2-finger detection starts fresh
            initialPinchDistance = distance
            lastPinchDistance = distance
            touchLastPosition = midpoint

        case 1: // Move
            let distanceChange = abs(distance - initialPinchDistance)
            let midDelta = hypot(midpoint.x - touchLastPosition.x, midpoint.y - touchLastPosition.y)

            // Determine mode if not yet decided
            if gestureState != .twoFingerScroll && gestureState != .pinching {
                if distanceChange > GestureThresholds.pinchMinDistance {
                    gestureState = .pinching
                } else if midDelta > GestureThresholds.tapMaxDistance {
                    gestureState = .twoFingerScroll
                }
            }

            switch gestureState {
            case .twoFingerScroll:
                let dx = (midpoint.x - touchLastPosition.x) * GestureThresholds.scrollSensitivity
                let dy = (midpoint.y - touchLastPosition.y) * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: dx, deltaY: dy, at: midpoint)

            case .pinching:
                let scaleDelta = distance - lastPinchDistance
                // Cmd + scroll = zoom in most Mac apps
                let zoomAmount = Int32(scaleDelta * 0.5)
                if zoomAmount != 0 {
                    injectZoomEvent(delta: zoomAmount, at: midpoint)
                }
                lastPinchDistance = distance

            default:
                break
            }

            touchLastPosition = midpoint

        case 2: // Up
            gestureState = .idle
            // Reset 1-finger tracking so leftover moves don't trigger scroll
            touchStartPosition = .zero
            touchLastPosition = .zero

        default:
            break
        }
    }

    // MARK: - Event Injection

    private func moveCursor(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func performClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDragged(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseUp(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        scrollEvent.post(tap: .cghidEventTap)
    }

    private func injectZoomEvent(delta: Int32, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        // Set Cmd flag for zoom
        scrollEvent.flags = .maskCommand
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Long Press Timer

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()
        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position
        let timer = DispatchSource.makeTimerSource(queue: inputQueue)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.momentumTick()
        }
        timer.resume()
        momentumTimer = timer
    }

    private func momentumTick() {
        let decay: CGFloat = 0.92
        let minVelocity: CGFloat = 0.5

        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)
        momentumVelocityX *= decay
        momentumVelocityY *= decay
    }

    private func stopMomentumScroll() {
        momentumTimer?.cancel()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop momentum scrolling
        inputQueue.sync {
            stopMomentumScroll()
        }

        // Stop server and cleanup
        stopServer()

        // Cancel all combine subscriptions
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Menu bar quick actions

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live status line (not clickable)
        let statusTitle: String
        if settings.isRunning {
            if settings.clientConnected {
                let device = settings.currentWirelessDevice ?? "tablet"
                statusTitle = "🟢 Connected — \(device)"
            } else {
                statusTitle = "🟡 Waiting for tablet on port \(settings.port)"
            }
        } else {
            statusTitle = "⚪️ Server stopped"
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Start / Stop
        let toggle = NSMenuItem(
            title: settings.isRunning ? "Stop Streaming" : "Start Streaming",
            action: #selector(toggleServerFromMenu),
            keyEquivalent: "t"
        )
        toggle.target = self
        // Mirror the settings-window Start button: starting needs the Screen
        // Screen Recording preflight is advisory; let the real capture path
        // decide whether this build can stream and surface its actual error.
        toggle.isEnabled = true
        menu.addItem(toggle)

        // Connection mode (switching while running restarts the server, same
        // as changing it in the settings window)
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        let usb = NSMenuItem(title: "USB", action: #selector(selectUSBMode), keyEquivalent: "")
        usb.target = self
        usb.state = settings.connectionMode == .usb ? .on : .off
        modeMenu.addItem(usb)
        let wireless = NSMenuItem(title: "Wireless", action: #selector(selectWirelessMode), keyEquivalent: "")
        wireless.target = self
        wireless.state = settings.connectionMode == .wireless ? .on : .off
        modeMenu.addItem(wireless)
        let modeItem = NSMenuItem(title: "Connection Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let brightnessItem = NSMenuItem()
        let brightnessView = BrightnessMenuItemView(
            level: nativeBrightness?.level ?? settings.brightnessLevel
        )
        brightnessView.onChange = { [weak self] level in
            guard let self else { return }
            if let controller = self.nativeBrightness {
                controller.setLevel(level)
            } else {
                // Keep the control useful before the server starts; the
                // controller reads this persisted value on the next session.
                self.settings.updateBrightnessFromController(level)
            }
        }
        brightnessItem.view = brightnessView
        menu.addItem(brightnessItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "s")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tablet Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
