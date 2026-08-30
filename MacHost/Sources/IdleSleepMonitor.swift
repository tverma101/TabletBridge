import Foundation

/// IdleSleepMonitor — pause the capture pipeline when no client is connected.
///
/// The sender normally captures + encodes at full rate whether or not a tablet
/// is attached (measured: ~97% CPU with no client, encoding frames into the
/// void). This monitor watches the client-connected flag; once the grace
/// window passes with no client, it pauses the SCStream capture so the encoder
/// goes idle (CPU ~0). When a client connects, it resumes capture and forces a
/// keyframe — the cached-frame replay covers the SCStream restart gap, so the
/// client sees pixels immediately.
///
/// Knobs:
///   defaults write dev.tabletbridge.host SideScreen_exp_idleSleep -bool true
///   defaults write dev.tabletbridge.host SideScreen_exp_idleSleepSecs -int 15
/// Gate is off by default — production behavior unchanged when unset.
final class IdleSleepMonitor {
    private let isClientConnected: () -> Bool
    private let pause: () -> Void
    private let resume: () -> Void
    private let graceSecs: Double

    private var timer: Timer?
    private var idleSince: Date?
    private var paused = false

    init(
        isClientConnected: @escaping () -> Bool,
        pause: @escaping () -> Void,
        resume: @escaping () -> Void,
        graceSecs: Double
    ) {
        self.isClientConnected = isClientConnected
        self.pause = pause
        self.resume = resume
        self.graceSecs = graceSecs
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if isClientConnected() {
            idleSince = nil
            if paused {
                paused = false
                resume()
            }
        } else {
            if let since = idleSince {
                if !paused, Date().timeIntervalSince(since) >= graceSecs {
                    paused = true
                    pause()
                }
            } else {
                idleSince = Date()
            }
        }
    }
}
