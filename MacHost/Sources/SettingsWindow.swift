import Cocoa
import SwiftUI

// MARK: - Frosted GroupBox Component

struct FrostedGroupBox<Content: View, Trailing: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

extension FrostedGroupBox where Trailing == EmptyView {
    init(title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
        self.trailing = EmptyView()
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings
    @State private var showPermissionAlert = false
    @State private var showResetConfirmation = false
    @State private var headerHovered = false
    @State private var daemonEnabled = false

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with frosted glass
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 48, height: 48)
                            .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 4)

                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .scaleEffect(headerHovered ? 1.05 : 1)
                    .animation(.spring(response: 0.3), value: headerHovered)
                    .onHover { headerHovered = $0 }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tablet Bridge")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Turn your tablet into a second display")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: { showResetConfirmation = true }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background {
                                Circle().fill(.ultraThinMaterial)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Reset settings")
                    .alert("Reset Settings", isPresented: $showResetConfirmation) {
                        Button("Cancel", role: .cancel) { }
                        Button("Reset", role: .destructive) {
                            settings.resetToDefaults()
                            if let window = NSApp.windows.first(where: { $0.title == "Tablet Bridge" }) {
                                window.center()
                            }
                        }
                    } message: {
                        Text("This will reset all settings to default values.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(.ultraThinMaterial)

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                // Connection mode picker — pinned, NOT scrollable.
                HStack(spacing: 6) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Button(action: { settings.connectionMode = mode }) {
                            HStack(spacing: 4) {
                                Image(systemName: mode == .usb ? "cable.connector" : "wifi")
                                Text(mode == .usb ? "USB" : "Wireless")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(settings.connectionMode == mode ? Color.accentColor : Color.clear)
                            .foregroundColor(settings.connectionMode == mode ? .white : .primary)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Display Configuration
                        FrostedGroupBox(title: "Display Configuration", icon: "display") {
                            VStack(alignment: .leading, spacing: 16) {
                                // Fixed tablet profile. Alternate and custom
                                // resolutions are intentionally not exposed.
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Resolution")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    HStack {
                                        Text("1400 × 876")
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        Spacer()
                                        Text("HiDPI · 2800 × 1752 physical")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                                }

                                // HiDPI (Retina)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("HiDPI (Retina)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Text("Fixed at 2× resolution for sharper text.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    Spacer()
                                    Text("On")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }

                                // Rotation
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Rotation")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)

                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                                                .frame(width: 80, height: 50)
                                                .scaleEffect(x: settings.flipHorizontal ? -1 : 1, y: settings.flipVertical ? -1 : 1)
                                                .rotationEffect(.degrees(Double(settings.rotation)))

                                            Text(settings.rotation == 90 || settings.rotation == 270 ? "Portrait" : "Landscape")
                                                .font(.system(size: 8))
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 100, height: 80)

                                        VStack(spacing: 6) {
                                            HStack(spacing: 6) {
                                                RotationButton(degrees: 270, label: "270", isSelected: settings.rotation == 270) {
                                                    settings.rotation = 270
                                                }
                                                RotationButton(degrees: 0, label: "0", isSelected: settings.rotation == 0) {
                                                    settings.rotation = 0
                                                }
                                                RotationButton(degrees: 90, label: "90", isSelected: settings.rotation == 90) {
                                                    settings.rotation = 90
                                                }
                                            }
                                            HStack(spacing: 6) {
                                                Spacer()
                                                RotationButton(degrees: 180, label: "180", isSelected: settings.rotation == 180) {
                                                    settings.rotation = 180
                                                }
                                                Spacer()
                                            }
                                        }
                                    }

                                    if settings.rotation == 90 || settings.rotation == 270 {
                                        Text("Display will be in portrait mode")
                                            .font(.system(size: 10))
                                            .foregroundColor(.accentColor)
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Flip Horizontally")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                                Text("Mirror left and right")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary.opacity(0.7))
                                            }
                                            Spacer()
                                            Toggle("", isOn: $settings.flipHorizontal)
                                                .toggleStyle(.switch)
                                                .controlSize(.mini)
                                        }

                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Flip Vertically")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                                Text("Mirror top and bottom")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary.opacity(0.7))
                                            }
                                            Spacer()
                                            Toggle("", isOn: $settings.flipVertical)
                                                .toggleStyle(.switch)
                                                .controlSize(.mini)
                                        }
                                    }
                                    .padding(.top, 4)

                                    HStack {
                                        Spacer()
                                        Button(action: {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.displays?displayArrangement")!)
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "rectangle.connected.to.line.below")
                                                Text("Arrange Displays…")
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(.top, 10)
                                }

                            }
                        }

                        // Tablet backlight. This is deliberately app-owned:
                        // the virtual display has no physical IODisplay
                        // backlight endpoint for macOS Displays to control.
                        FrostedGroupBox(title: "Tablet Brightness", icon: "sun.max") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Brightness")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(settings.brightnessPercent)%")
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                }

                                HStack(spacing: 8) {
                                    Image(systemName: "sun.min")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .accessibilityHidden(true)
                                    Slider(
                                        value: $settings.brightness,
                                        in: NativeBrightnessController.normalizedValue(
                                            for: UInt8(NativeBrightnessController.minimumLevel)
                                        )...1.0
                                    )
                                    .accessibilityLabel("Tablet Bridge tablet brightness")
                                    .accessibilityValue("\(settings.brightnessPercent) percent")
                                    Image(systemName: "sun.max")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .accessibilityHidden(true)
                                }

                                Text("Controls the tablet panel directly and is remembered for the next connection. F1/F2 also adjust it.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Refresh Rate (own block)
                        FrostedGroupBox(title: "Refresh Rate", icon: "speedometer") {
                            VStack(alignment: .leading, spacing: 8) {
                                let displayedRefreshRate = WirelessSessionProfile.frameRate(
                                    for: settings.connectionMode,
                                    requested: settings.effectiveRefreshRate
                                )
                                HStack {
                                    Text("Frame Rate")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(displayedRefreshRate) Hz")
                                        .font(.system(size: 11, weight: .medium))
                                }

                                HStack(spacing: 6) {
                                    ForEach([30, 60, 90, 120], id: \.self) { rate in
                                        BitrateButton(
                                            label: "\(rate)",
                                            value: rate,
                                            currentValue: displayedRefreshRate,
                                            disabled: settings.connectionMode == .wireless && rate > WirelessSessionProfile.frameRate
                                        ) {
                                            settings.refreshRate = rate
                                        }
                                    }
                                }

                                if settings.connectionMode == .wireless {
                                    Text("Wireless is fixed at 60 FPS for stable Wi-Fi and lower tablet power use.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                } else if settings.refreshRate >= 90 {
                                    Text("High refresh rate for smooth experience")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                }
                            }
                        }

                        // Touch Control
                        FrostedGroupBox(title: "Touch Control", icon: "hand.tap") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Enable Touch Input")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Control Mac from tablet touch")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.touchEnabled)
                                        .labelsHidden()
                                }

                                if !settings.touchEnabled {
                                    Text("Touch input is disabled — tablet is display-only")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            }
                        }

                        // Network Settings (port — applies to both modes; listener binds on it)
                        FrostedGroupBox(title: "Network Settings", icon: "network") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Server Port")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    TextField("Port", value: $settings.port, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        .disabled(settings.isRunning)
                                }

                                if settings.isRunning {
                                    Text("Stop server to change port")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                } else if settings.connectionMode == .wireless {
                                    Text("Changing the port invalidates existing pairings — re-scan the QR on each tablet.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                } else if settings.port != 54321 {
                                    Text("Custom port set — Android client must use the same port.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Wireless-mode-only: QR + Paired Devices.
                        if settings.connectionMode == .wireless {
                            WirelessSection(settings: settings,
                                            pairedDeviceStore: (NSApp.delegate as? AppDelegate)?.pairedDeviceStore ?? PairedDeviceStore())
                        }

                        // Startup / headless behaviour
                        FrostedGroupBox(title: "Startup", icon: "power") {
                            VStack(alignment: .leading, spacing: 12) {
                                if #available(macOS 13.0, *) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Launch at Login")
                                                .font(.system(size: 12, weight: .medium))
                                            Text("Run Tablet Bridge in the background automatically after you log in.")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { daemonEnabled },
                                            set: { newValue in
                                                do {
                                                    if newValue {
                                                        try DaemonManager.shared.enable()
                                                    } else {
                                                        try DaemonManager.shared.disable()
                                                    }
                                                } catch {
                                                    print("Daemon toggle failed: \(error)")
                                                }
                                                daemonEnabled = DaemonManager.shared.isEnabled
                                            }
                                        ))
                                        .labelsHidden()
                                    }
                                    Divider()
                                }

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Auto-start streaming on launch")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Start the server automatically when the app opens, so the tablet can connect without touching the Mac.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.autoStartStreamingOnLaunch)
                                        .labelsHidden()
                                }

                                Divider()

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Startup mode")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Which connection mode to start in when auto-starting.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Picker("", selection: $settings.startupMode) {
                                        Text("USB").tag(ConnectionMode.usb)
                                        Text("Wireless").tag(ConnectionMode.wireless)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 150)
                                    .disabled(!settings.autoStartStreamingOnLaunch)
                                }
                            }
                        }
                        .onAppear {
                            if #available(macOS 13.0, *) {
                                daemonEnabled = DaemonManager.shared.isEnabled
                            }
                        }

                        // Gaming Boost
                        FrostedGroupBox(title: "Gaming Boost", icon: settings.gamingBoost ? "bolt.fill" : "bolt") {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Enable Gaming Mode")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Optimized for competitive gaming")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.gamingBoost)
                                        .labelsHidden()
                                }

                                if settings.gamingBoost {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text("High bitrate (1000 Mbps)")
                                                .font(.system(size: 11))
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text("120 Hz refresh rate")
                                                .font(.system(size: 11))
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text("Ultra-low latency encoding")
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .padding(.leading, 4)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Streaming Settings
                        FrostedGroupBox(title: "Streaming Settings", icon: "antenna.radiowaves.left.and.right") {
                            VStack(alignment: .leading, spacing: 16) {
                                // Bitrate
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Bitrate")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(settings.effectiveBitrate) Mbps")
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.accentColor)
                                    }

                                    HStack(spacing: 6) {
                                        BitrateButton(label: "100", value: 100, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 100
                                        }
                                        BitrateButton(label: "300", value: 300, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 300
                                        }
                                        BitrateButton(label: "500", value: 500, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 500
                                        }
                                        BitrateButton(label: "1000", value: 1000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 1000
                                        }
                                        BitrateButton(label: "2000", value: 2000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 2000
                                        }
                                    }

                                    HStack(spacing: 8) {
                                        Text("20")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        Slider(value: Binding(
                                            get: { Double(settings.bitrate) },
                                            set: { settings.bitrate = Int($0) }
                                        ), in: 20...5000, step: 10)
                                        .disabled(settings.gamingBoost)
                                        Text("5000")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }

                                    if settings.gamingBoost {
                                        HStack(spacing: 4) {
                                            Image(systemName: "bolt.fill")
                                                .font(.system(size: 10))
                                            Text("Locked at 1000 Mbps in Gaming Boost")
                                                .font(.system(size: 10))
                                        }
                                        .foregroundColor(.orange)
                                    }
                                }

                                // Quality
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Quality Preset")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)

                                    Picker("", selection: $settings.quality) {
                                        Text("Ultra Low").tag("ultralow")
                                        Text("Low").tag("low")
                                        Text("Medium").tag("medium")
                                        Text("High").tag("high")
                                        // EXP-FORK: Ultra ladder (quality campaign)
                                        Text("Extra High").tag("extrahigh")
                                        Text("Max").tag("max")
                                        Text("Ultra").tag("ultra")
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(settings.gamingBoost)

                                    if settings.gamingBoost {
                                        Text("Quality locked to Ultra Low in Gaming Boost mode")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                    } else if settings.quality == "ultralow" {
                                        Text("Fastest encoding, lowest latency")
                                            .font(.system(size: 10))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }

                        // Status
                        FrostedGroupBox(title: "Status", icon: "checkmark.circle") {
                            VStack(alignment: .leading, spacing: 12) {
                                StatusRow(title: "Virtual Display",
                                          status: settings.displayCreated ? "Active" : "Inactive",
                                          color: settings.displayCreated ? .green : .secondary,
                                          hint: "The macOS virtual display we render into. Created when you click Start; the tablet streams its pixels.")
                                StatusRow(title: "Client Connected",
                                          status: settings.clientConnected ? "Yes" : "No",
                                          color: settings.clientConnected ? .green : .secondary,
                                          hint: "Whether the Android client app currently has an active stream session.")
                                StatusRow(
                                    title: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Screen & System Audio" : "Screen Recording",
                                    status: settings.screenCaptureOperational
                                        ? "Capture working"
                                        : (settings.screenCaptureFailure == nil ? settings.screenRecordingPermission.statusText : "Capture unavailable"),
                                    color: settings.screenCaptureOperational || (settings.screenCaptureFailure == nil && settings.hasScreenRecordingPermission) ? .green : .red,
                                    hint: settings.screenCaptureOperational
                                        ? "The actual capture setup succeeded for this running bundle. The Core Graphics preflight result is advisory."
                                        : (settings.screenCaptureFailure ?? settings.screenRecordingPermission.diagnosticText)
                                )
                                StatusRow(title: "Accessibility",
                                          status: settings.hasAccessibilityPermission ? "Granted" : "Optional",
                                          color: settings.hasAccessibilityPermission ? .green : .orange,
                                          hint: "Optional permission. Required only if you want touch/tap input from the tablet to control the Mac. Streaming works without it.")
                                if settings.isRunning {
                                    StatusRow(title: "Capture Method",
                                              status: settings.captureMethod,
                                              color: settings.screenCaptureOperational ? .green : (settings.captureMethod.hasPrefix("Unavailable") ? .red : .orange),
                                              hint: "ScreenCaptureKit is the only capture path. This reports Starting until the first frame arrives, or Unavailable with the actual failure.")
                                }

                                // Mode-aware contextual rows
                                Divider().padding(.vertical, 4)
                                if settings.connectionMode == .usb {
                                    StatusRow(title: "ADB installed",
                                              status: settings.adbInstalled ? "Installed" : "Missing",
                                              color: settings.adbInstalled ? .green : .red,
                                              hint: "USB mode tunnels the TCP stream through the cable using `adb reverse`. Requires the `adb` command on the Mac. Searched paths: Homebrew, /usr/local/bin, ~/Library/Android/sdk/platform-tools, and PATH (`which adb`).")
                                    if !settings.adbInstalled {
                                        Text("brew install android-platform-tools")
                                            .font(.system(size: 10, design: .monospaced))
                                            .padding(6)
                                            .background(Color.black.opacity(0.08))
                                            .cornerRadius(4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                    StatusRow(title: "ADB reverse",
                                              status: settings.adbReverseConfigured ? "OK" : "Pending",
                                              color: settings.adbReverseConfigured ? .green : .orange,
                                              hint: "Whether `adb reverse tcp:\(settings.port) tcp:\(settings.port)` is currently configured. The Mac app sets this up automatically when you click Start. Goes green within ~2 seconds after the tablet is plugged in and authorized.")
                                    StatusRow(title: "USB device",
                                              status: settings.usbDeviceConnected ? "Detected" : "Not detected",
                                              color: settings.usbDeviceConnected ? .green : .red,
                                              hint: "An Android device authorized for ADB and visible to your Mac. Plug in via USB-C and tap Allow on the device's USB debugging prompt.")
                                } else {
                                    StatusRow(title: "WiFi",
                                              status: settings.wifiConnected ? "Connected" : "Disconnected",
                                              color: settings.wifiConnected ? .green : .red,
                                              hint: "Whether the Mac currently has a working internet route. Wireless mode requires the Mac to be on a WiFi (or Ethernet) network — the same network the tablet is on.")
                                    StatusRow(title: "Listening on",
                                              status: settings.listeningAddress.map { "\($0):\(settings.port)" } ?? "—",
                                              color: settings.listeningAddress != nil ? .green : .secondary,
                                              hint: "The LAN address the tablet must reach. The QR code embeds this exact host:port — if it changes (e.g. you switch WiFi), re-scan the new QR on the tablet.")
                                }

                                if !settings.hasScreenRecordingPermission && !settings.screenCaptureOperational {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundColor(.orange)
                                            Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Screen & System Audio Recording Required" : "Screen Recording Required")
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                                            ? "Required to capture the virtual display. Go to System Settings > Privacy & Security > Screen & System Audio Recording."
                                            : "Required to capture the virtual display.")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Text(settings.screenRecordingPermission.diagnosticText)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        if let failure = settings.screenCaptureFailure {
                                            Text("Capture attempt: \(failure). The host remains available because the preflight result is advisory.")
                                                .font(.system(size: 11))
                                                .foregroundColor(.orange)
                                        }
                                        Text("Running bundle")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        Text(settings.screenRecordingPermission.bundlePath)
                                            .font(.system(size: 10, design: .monospaced))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if !settings.screenRecordingPermission.isCanonicalInstall {
                                            Text("Canonical install: \(settings.screenRecordingPermission.canonicalInstallPath)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.orange)
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Text(settings.screenRecordingPermission.recoveryText)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        HStack(spacing: 8) {
                                            Button(action: {
                                                settings.requestScreenRecordingPermission()
                                            }) {
                                                HStack {
                                                    Image(systemName: "record.circle")
                                                    Text("Request Access")
                                                }
                                            }
                                            .buttonStyle(.borderedProminent)

                                            Button(action: {
                                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                            }) {
                                                HStack {
                                                    Image(systemName: "gear")
                                                    Text("Open Settings")
                                                }
                                            }
                                            .buttonStyle(.bordered)

                                            Button(action: {
                                                settings.refreshScreenRecordingPermission()
                                            }) {
                                                HStack {
                                                    Image(systemName: "arrow.clockwise")
                                                    Text("Recheck")
                                                }
                                            }
                                            .buttonStyle(.bordered)

                                            Button(action: {
                                                settings.copyScreenRecordingIdentity()
                                            }) {
                                                HStack {
                                                    Image(systemName: "doc.on.doc")
                                                    Text("Copy Identity")
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                        .controlSize(.small)
                                    }
                                    .padding(10)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(8)
                                }

                                if !settings.hasAccessibilityPermission {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "hand.tap.fill")
                                                .foregroundColor(.blue)
                                            Text("Enable Touch Control")
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        Text("Control your Mac from your tablet.")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Button(action: {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                        }) {
                                            HStack {
                                                Image(systemName: "gear")
                                                Text("Open Settings")
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(10)
                                    .background(Color.blue.opacity(0.08))
                                    .cornerRadius(8)
                                }
                            }
                        }

                        // Performance (when connected)
                        if settings.clientConnected {
                            FrostedGroupBox(title: "Performance", icon: "speedometer") {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("FPS")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f", settings.currentFPS))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.green)
                                    }
                                    Spacer()
                                    VStack(alignment: .leading) {
                                        Text("Bitrate")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f Mbps", settings.currentBitrate))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }

                // Footer
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1)

                    HStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                settings.toggleServer()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: settings.isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 12))
                                Text(settings.isRunning ? "Stop" : "Start")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .frame(width: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(settings.isRunning ? .red : .accentColor)
                        .controlSize(.large)

                        if settings.isRunning {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                    .overlay {
                                        Circle()
                                            .stroke(Color.green.opacity(0.3), lineWidth: 2)
                                            .scaleEffect(1.5)
                                    }
                                Text("Running on port \(settings.port)")
                                    .font(.system(size: 12))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                Capsule().fill(.ultraThinMaterial)
                                    .overlay {
                                        Capsule().strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
                                    }
                            }
                            .transition(.scale.combined(with: .opacity))
                        }

                        Spacer()

                        // Restart button
                        Button(action: {
                            restartApp()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .background {
                                    Circle().fill(.ultraThinMaterial)
                                        .overlay {
                                            Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Restart App")

                        // Quit button
                        Button(action: {
                            NSApp.terminate(nil)
                        }) {
                            Image(systemName: "power")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .background {
                                    Circle().fill(.ultraThinMaterial)
                                        .overlay {
                                            Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Quit Tablet Bridge (⌘Q)")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .frame(width: 480, height: 780)
    }

    /// Restart the app by launching a new instance and terminating current one
    private func restartApp() {
        // Get the app bundle path
        guard let appPath = Bundle.main.bundlePath as String? else {
            print("❌ Could not get app path")
            return
        }

        // Use Process to launch a new instance after a short delay
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open \"\(appPath)\""]

        do {
            try task.run()
            // Terminate current app
            NSApp.terminate(nil)
        } catch {
            print("❌ Failed to restart: \(error)")
        }
    }
}

// MARK: - Supporting Views

struct StatusRow: View {
    let title: String
    let status: String
    let color: Color
    var hint: String?
    @State private var showHint = false
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            if let hint = hint {
                Button(action: { showHint.toggle() }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(hovering ? .accentColor : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(hint)
                .popover(isPresented: $showHint, arrowEdge: .top) {
                    Text(hint)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(12)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(color)
            }
        }
    }
}

struct BitrateButton: View {
    let label: String
    let value: Int
    let currentValue: Int
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var isSelected: Bool { currentValue == value }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            }
                    }
                }
                .foregroundColor(isSelected ? .white : (disabled ? .secondary : .primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }
}

struct RotationButton: View {
    let degrees: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: degrees == 90 || degrees == 270 ? 16 : 24, height: degrees == 90 || degrees == 270 ? 24 : 16)

                Text("\(label)")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(width: 50, height: 40)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Display Settings

class DisplaySettings: ObservableObject {
    private let defaults = UserDefaults.standard
    // Keep the inherited defaults namespace so existing installations retain
    // their settings across the fork's bundle-identity change.
    private let keyPrefix = "SideScreen_"

    @Published var resolution: String {
        didSet { save("resolution", resolution) }
    }
    @Published var refreshRate: Int {
        didSet { save("refreshRate", refreshRate) }
    }
    @Published var hiDPI: Bool {
        didSet { save("hiDPI", hiDPI) }
    }
    @Published var bitrate: Int {
        didSet { save("bitrate", bitrate) }
    }
    @Published var quality: String {
        didSet { save("quality", quality) }
    }
    @Published var gamingBoost: Bool {
        didSet { save("gamingBoost", gamingBoost) }
    }
    @Published var port: UInt16 {
        didSet { save("port", Int(port)) }
    }
    @Published var rotation: Int {
        didSet { save("rotation", rotation) }
    }
    @Published var flipHorizontal: Bool {
        didSet { save("flipHorizontal", flipHorizontal) }
    }
    @Published var flipVertical: Bool {
        didSet { save("flipVertical", flipVertical) }
    }
    @Published var brightness: Double {
        didSet {
            let level = NativeBrightnessController.level(forNormalizedValue: brightness)
            defaults.set(level, forKey: NativeBrightnessController.defaultsKey)
        }
    }
    @Published var touchEnabled: Bool {
        didSet { save("touchEnabled", touchEnabled) }
    }
    @Published var connectionMode: ConnectionMode {
        didSet { save("connectionMode", connectionMode.rawValue) }
    }
    @Published var autoStartStreamingOnLaunch: Bool {
        didSet { save("autoStartStreamingOnLaunch", autoStartStreamingOnLaunch) }
    }
    @Published var startupMode: ConnectionMode {
        didSet { save("startupMode", startupMode.rawValue) }
    }

    // Runtime state (not persisted)
    @Published var displayCreated = false
    @Published var clientConnected = false
    /// Device name of the wireless client currently streaming (nil when none).
    /// WirelessSection reads this to show a "Connected" badge on the matching row.
    @Published var currentWirelessDevice: String?
    @Published private(set) var screenRecordingPermission = ScreenRecordingPermissionSnapshot.initial()
    var hasScreenRecordingPermission: Bool { screenRecordingPermission.isGranted }
    @Published var screenCaptureOperational = false
    @Published var screenCaptureFailure: String? = nil
    @Published var hasAccessibilityPermission = false
    @Published var adbInstalled = false
    @Published var adbReverseConfigured = false
    @Published var usbDeviceConnected = false
    @Published var wifiConnected = false
    @Published var listeningAddress: String?
    @Published var isRunning = false
    @Published var currentFPS: Double = 0
    @Published var currentBitrate: Double = 0
    @Published var captureMethod: String = "Initializing..."

    var onToggleServer: (() -> Void)?
    var onRequestScreenRecordingPermission: (() -> Void)?
    var onRefreshScreenRecordingPermission: (() -> Void)?
    var onCopyScreenRecordingIdentity: (() -> Void)?

    static let fixedResolution = "1400x876"

    init() {
        // This client is paired with the 2800×1752 tablet. Keep the logical
        // profile fixed at 1400×876 HiDPI so stale or accidental preferences
        // cannot create a mismatched virtual display.
        self.resolution = Self.fixedResolution
        self.refreshRate = defaults.object(forKey: keyPrefix + "refreshRate") as? Int ?? 60  // Default: 60 — balanced for most tablets. 120 may saturate high-res panel pipelines.
        self.hiDPI = true
        self.bitrate = defaults.object(forKey: keyPrefix + "bitrate") as? Int ?? 1000  // Default: 1000 Mbps
        self.quality = defaults.string(forKey: keyPrefix + "quality") ?? "ultralow"  // Default: fastest encoding
        self.gamingBoost = defaults.bool(forKey: keyPrefix + "gamingBoost")
        // Default port 54321 (was 8888 in <=0.7.1; 8888 collides with jupyter/splunk/HP printers).
        // Existing users keep their saved value.
        self.port = UInt16(defaults.object(forKey: keyPrefix + "port") as? Int ?? 54321)
        self.rotation = defaults.object(forKey: keyPrefix + "rotation") as? Int ?? 0
        self.flipHorizontal = defaults.bool(forKey: keyPrefix + "flipHorizontal")
        self.flipVertical = defaults.bool(forKey: keyPrefix + "flipVertical")
        self.brightness = NativeBrightnessController.normalizedValue(
            for: UInt8(NativeBrightnessController.persistedLevel)
        )
        self.touchEnabled = defaults.object(forKey: keyPrefix + "touchEnabled") as? Bool ?? true
        let modeRaw = defaults.string(forKey: keyPrefix + "connectionMode") ?? ConnectionMode.usb.rawValue
        self.connectionMode = ConnectionMode(rawValue: modeRaw) ?? .usb
        self.autoStartStreamingOnLaunch = defaults.object(forKey: keyPrefix + "autoStartStreamingOnLaunch") as? Bool ?? false
        let startupRaw = defaults.string(forKey: keyPrefix + "startupMode") ?? modeRaw
        self.startupMode = ConnectionMode(rawValue: startupRaw) ?? .usb

        defaults.set(Self.fixedResolution, forKey: keyPrefix + "resolution")
        defaults.set(true, forKey: keyPrefix + "hiDPI")
        print("Loaded fixed settings: \(resolution) @ \(refreshRate)Hz HiDPI, bitrate=\(bitrate), quality=\(quality)")
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    var effectiveBitrate: Int {
        return gamingBoost ? 1000 : bitrate
    }

    var effectiveQuality: String {
        return gamingBoost ? "ultralow" : quality
    }

    var effectiveRefreshRate: Int {
        return gamingBoost ? 120 : refreshRate
    }

    var brightnessPercent: Int {
        Int((brightness * 100.0).rounded())
    }

    var brightnessLevel: UInt8 {
        NativeBrightnessController.level(forNormalizedValue: brightness)
    }

    func updateBrightnessFromController(_ level: UInt8) {
        let normalized = NativeBrightnessController.normalizedValue(for: level)
        guard abs(brightness - normalized) > 0.0001 else { return }
        brightness = normalized
    }

    func toggleServer() {
        onToggleServer?()
    }

    func requestScreenRecordingPermission() {
        onRequestScreenRecordingPermission?()
    }

    @discardableResult
    func updateScreenRecordingPermission(_ snapshot: ScreenRecordingPermissionSnapshot) -> Bool {
        let changed = screenRecordingPermission != snapshot
        screenRecordingPermission = snapshot
        return changed
    }

    func refreshScreenRecordingPermission() {
        onRefreshScreenRecordingPermission?()
    }

    func copyScreenRecordingIdentity() {
        onCopyScreenRecordingIdentity?()
    }

    func resetToDefaults() {
        let keys = ["resolution", "refreshRate", "hiDPI", "bitrate", "quality",
                    "gamingBoost", "port", "rotation", "flipHorizontal", "flipVertical",
                    "touchEnabled", "autoStartStreamingOnLaunch", "startupMode"]
        for key in keys {
            defaults.removeObject(forKey: keyPrefix + key)
        }

        resolution = Self.fixedResolution
        refreshRate = 120  // Default: highest FPS
        hiDPI = true
        bitrate = 1000  // Default: 1000 Mbps
        quality = "ultralow"  // Default: fastest encoding
        gamingBoost = false
        port = 54321
        rotation = 0
        flipHorizontal = false
        flipVertical = false
        touchEnabled = true
        autoStartStreamingOnLaunch = false
        startupMode = .usb

        print("Settings reset to defaults")
    }

    var resolutionSize: (width: Int, height: Int) {
        let parts = resolution.split(separator: "x")
        let baseWidth = Int(parts[0]) ?? 1920
        let baseHeight = Int(parts[1]) ?? 1200
        if rotation == 90 || rotation == 270 {
            return (baseHeight, baseWidth)
        }
        return (baseWidth, baseHeight)
    }

}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(settings: DisplaySettings) {
        let window = ConstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 780),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Tablet Bridge"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        var frame = window.frame
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if frame.maxX < visibleFrame.minX + minVisibleWidth {
            frame.origin.x = visibleFrame.minX - frame.width + minVisibleWidth
        } else if frame.minX > visibleFrame.maxX - minVisibleWidth {
            frame.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if frame.maxY < visibleFrame.minY + minVisibleHeight {
            frame.origin.y = visibleFrame.minY - frame.height + minVisibleHeight
        } else if frame.minY > visibleFrame.maxY - minVisibleHeight {
            frame.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
}

class ConstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? self.screen ?? NSScreen.main else {
            return frameRect
        }

        var constrainedRect = frameRect
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if constrainedRect.maxX < visibleFrame.minX + minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.minX - constrainedRect.width + minVisibleWidth
        } else if constrainedRect.minX > visibleFrame.maxX - minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if constrainedRect.maxY < visibleFrame.minY + minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.minY - constrainedRect.height + minVisibleHeight
        } else if constrainedRect.minY > visibleFrame.maxY - minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        return constrainedRect
    }
}

// MARK: - Wireless Section

struct WirelessSection: View {
    @ObservedObject var settings: DisplaySettings
    let pairedDeviceStore: PairedDeviceStore
    @State private var qrImage: NSImage?
    @State private var pairedDevices: [PairedDevice] = []
    @State private var showResetConfirm = false
    /// Used to force the relative-time labels to recompute every tick even when
    /// the underlying lastConnected timestamp hasn't changed (e.g. while a
    /// device is disconnected and we still want "5 minutes ago" to count up).
    @State private var nowTick: Date = Date()

    var body: some View {
        VStack(spacing: 12) {
            if !settings.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Click Start at the top to begin listening, then scan the QR.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }
            FrostedGroupBox(title: "Pair Device", icon: "qrcode") {
                VStack(spacing: 8) {
                    if let qr = qrImage {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .padding(8)
                            .background(Color.white)
                            .cornerRadius(8)
                    } else {
                        Text("Generating QR…").foregroundColor(.secondary)
                    }
                    Text("Scan this QR from Tablet Bridge Android (Wireless tab)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text(LANAddressResolver.primaryIPv4().map { "Listening: \($0):\(settings.port)" } ?? "WiFi disconnected — no LAN address")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            FrostedGroupBox(
                title: "Paired Devices (\(pairedDevices.count))",
                icon: "ipad.and.iphone",
                content: {
                if pairedDevices.isEmpty {
                    Text("No devices paired yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(pairedDevices, id: \.name) { device in
                            let isLive = settings.currentWirelessDevice == device.name
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.system(size: 12, weight: .medium))
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(isLive ? Color.green : Color.secondary)
                                            .frame(width: 6, height: 6)
                                        Text(isLive ? "Connected" : relativeTimeString(from: device.lastConnected, to: nowTick))
                                            .font(.system(size: 10))
                                            .foregroundColor(isLive ? .green : .secondary)
                                    }
                                }
                                Spacer()
                                Button("Forget") {
                                    pairedDeviceStore.forget(name: device.name)
                                    refreshPaired()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                        }
                    }
                }
                Button("Reset Token (forget all)") {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.red)
                .padding(.top, 6)
            },
            trailing: {
                Button(action: {
                    nowTick = Date()
                    refreshPaired()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh list and timestamps")
            })
        }
        .onAppear {
            refreshQR()
            refreshPaired()
            nowTick = Date()
        }
        // One-parameter onChange(of:perform:) works on macOS 13+. The
        // two-parameter form requires macOS 14 and would block Ventura.
        // Deprecation is a compile-time warning only on Xcode 15+ SDKs.
        .onChange(of: settings.port) { _ in refreshQR() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { now in
            nowTick = now
            refreshPaired()
        }
        .alert("Reset Token?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                _ = WirelessAuth.reset()
                pairedDeviceStore.clear()
                refreshQR()
                refreshPaired()
            }
        } message: {
            Text("This will disconnect all paired devices. They will need to scan the new QR to connect again.")
        }
    }

    private func refreshQR() {
        let token = WirelessAuth.loadOrCreate()
        let host = LANAddressResolver.primaryIPv4() ?? "0.0.0.0"
        let name = Host.current().localizedName ?? "Mac"
        let url = PairingURL.build(host: host, port: settings.port, token: token, name: name)
        qrImage = QRRenderer.render(url: url, size: 180)
    }

    private func refreshPaired() {
        pairedDevices = pairedDeviceStore.all()
    }

    private func relativeTimeString(from past: Date, to now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(past))
        if elapsed < 30 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed)) seconds ago" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = Int(elapsed / 86400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
