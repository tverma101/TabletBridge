import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo

/// Runtime bridge between ScreenCaptureKit metadata and AdaptiveRefreshPolicy.
///
/// The controller deliberately avoids reading pixel planes. ScreenCaptureKit
/// already tells us whether a frame is idle and which rectangles changed; that
/// metadata is enough to decide whether 8, 15, 30, 60, or a short >60-FPS
/// probe is justified.
final class AdaptiveRefreshController {
    private struct Observation {
        let isIdle: Bool
        let dirtyRatio: Double
    }

    private let lock = NSLock()
    private let width: Int
    private let height: Int
    private let displayBounds: CGRect?
    private var policy: AdaptiveRefreshPolicy
    private var appliedFPS: Int
    private var desiredFPS: Int
    private var desiredReason: AdaptiveRefreshPolicy.Reason = .warm
    private var updateInFlight = false
    private var lastObservationNs: UInt64 = 0
    private weak var currentStream: SCStream?
    private var idleTimer: DispatchSourceTimer?
    private var inputMonitor: Any?

    /// Default-on. Set `SideScreen_adaptiveRefresh = false` to get the old
    /// fixed-FPS behavior for A/B debugging.
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if let explicit = defaults.object(forKey: "SideScreen_adaptiveRefresh") as? NSNumber {
            return explicit.boolValue
        }
        return true
    }

    init(width: Int, height: Int, maxFPS: Int, gamingBoost: Bool, displayBounds: CGRect? = nil) {
        self.width = width
        self.height = height
        self.displayBounds = displayBounds
        let safeMax = max(1, maxFPS)
        self.policy = AdaptiveRefreshPolicy(
            maxFPS: safeMax,
            gamingBoost: gamingBoost,
            initialFPS: safeMax
        )
        self.appliedFPS = safeMax
        self.desiredFPS = safeMax
        installInputMonitor()
    }

    deinit {
        idleTimer?.cancel()
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
        }
    }

    func update(maxFPS: Int, gamingBoost: Bool) {
        lock.lock()
        policy.setMaxFPS(maxFPS)
        policy.setGamingBoost(gamingBoost)
        desiredFPS = min(desiredFPS, max(1, maxFPS))
        lock.unlock()
    }

    static func isPointerInsideCapturedDisplay(_ location: CGPoint, displayBounds: CGRect?) -> Bool {
        guard let displayBounds else { return false }
        return displayBounds.contains(location)
    }

    /// Feed one sample buffer. Returns true for ScreenCaptureKit `.idle`
    /// buffers, which the caller can drop before image processing/encoding.
    @discardableResult
    func observe(sampleBuffer: CMSampleBuffer, stream: SCStream?) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let observation = Self.observation(from: sampleBuffer)

        lock.lock()
        lastObservationNs = now
        if let stream {
            currentStream = stream
        }
        let decision = policy.observe(
            nowNs: now,
            isIdle: observation.isIdle,
            dirtyRatio: observation.dirtyRatio
        )
        lock.unlock()

        ensureIdleTimer()
        request(decision, stream: stream)
        return observation.isIdle
    }

    /// Pre-wake from user input before an 8/15-FPS ScreenCaptureKit cadence has
    /// a chance to add visible latency. Direct input gets the policy's stable
    /// 60-FPS interaction window; 120 FPS is reserved for Gaming Boost or
    /// validated high-cadence screen content. Plain mouse movement is accepted
    /// only on the captured virtual display, so a cursor on another Mac
    /// display cannot keep SideScreen warm indefinitely.
    private func installInputMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .keyDown,
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let token = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleInput(event)
            }
            self.lock.lock()
            self.inputMonitor = token
            self.lock.unlock()
        }
    }

    private func handleInput(_ event: NSEvent) {
        let highRate: Bool
        switch event.type {
        case .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            // A mouse move on the Mac's primary display must not keep a remote
            // SideScreen session warm. AppKit global-monitor locations are in
            // the same global coordinate space as CGDisplayBounds.
            guard Self.isPointerInsideCapturedDisplay(event.locationInWindow, displayBounds: displayBounds) else {
                return
            }
            highRate = true
        default:
            highRate = false
        }

        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let stream = currentStream
        let decision = policy.noteInteraction(nowNs: now, highRate: highRate)
        lock.unlock()
        request(decision, stream: stream)
    }

    /// ScreenCaptureKit can stop producing buffers entirely on an unchanged
    /// desktop. A 1-Hz watchdog advances only the *policy clock* after 500 ms
    /// of silence so the capture rate can still decay 60 -> 30 -> 15 -> 8
    /// without keeping a utility timer awake four times per second.
    /// It does not inspect pixels and remains dormant while normal frames flow.
    private func ensureIdleTimer() {
        lock.lock()
        if idleTimer != nil {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        idleTimer = timer
        lock.unlock()

        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.idleTick()
        }
        timer.resume()
    }

    private func idleTick() {
        let now = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        guard lastObservationNs > 0,
              now >= lastObservationNs,
              now - lastObservationNs >= 500_000_000 else {
            lock.unlock()
            return
        }
        let stream = currentStream
        let decision = policy.observe(nowNs: now, isIdle: true, dirtyRatio: 0)
        lock.unlock()

        request(decision, stream: stream)
    }

    private func request(_ decision: AdaptiveRefreshPolicy.Decision, stream: SCStream?) {
        guard let stream else { return }

        var shouldApply = false
        lock.lock()
        desiredFPS = decision.targetFPS
        desiredReason = decision.reason
        if !updateInFlight && desiredFPS != appliedFPS {
            updateInFlight = true
            shouldApply = true
        }
        lock.unlock()

        if shouldApply {
            applyNext(on: stream)
        }
    }

    /// Serializes live `updateConfiguration` calls. A new desired tier that
    /// arrives while an update is in flight is coalesced and applied next.
    private func applyNext(on stream: SCStream) {
        let target: Int
        let reason: AdaptiveRefreshPolicy.Reason
        lock.lock()
        target = desiredFPS
        reason = desiredReason
        lock.unlock()

        let config = Self.makeStreamConfiguration(width: width, height: height, fps: target)
        stream.updateConfiguration(config) { [weak self, weak stream] error in
            guard let self else { return }

            if let error {
                self.lock.lock()
                self.updateInFlight = false
                self.lock.unlock()
                debugLog("Adaptive refresh update to \(target)fps failed: \(error.localizedDescription)")
                return
            }

            self.lock.lock()
            let old = self.appliedFPS
            self.appliedFPS = target
            let needsAnotherUpdate = self.desiredFPS != target
            if !needsAnotherUpdate {
                self.updateInFlight = false
            }
            self.lock.unlock()

            if old != target {
                debugLog("Adaptive refresh: \(old) -> \(target) fps (\(reason.rawValue))")
            }

            if needsAnotherUpdate, let stream {
                self.applyNext(on: stream)
            }
        }
    }

    /// Single source of truth for the initial SCStream configuration and every
    /// adaptive FPS update. Keeping all non-FPS properties identical prevents
    /// `updateConfiguration` from accidentally resetting image quality knobs.
    static func makeStreamConfiguration(
        width: Int,
        height: Int,
        fps: Int,
        defaults: UserDefaults = .standard
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        config.pixelFormat = configuredPixelFormat(defaults: defaults)

        switch defaults.string(forKey: "SideScreen_exp_colorSpace") {
        case "displayP3":
            config.colorSpaceName = "kCGColorSpaceDisplayP3" as CFString
        case "bt2020":
            config.colorSpaceName = "kCGColorSpaceITUR_2020" as CFString
        case "srgb":
            config.colorSpaceName = "kCGColorSpaceSRGB" as CFString
        default:
            break
        }

        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = false
        config.backgroundColor = .clear
        config.scalesToFit = false
        return config
    }

    /// Resolve the capture range explicitly. The normal 8-bit path uses
    /// Apple's video-range 420v format so the HEVC bitstream and Android's
    /// default video-range decoder conversion agree. `8bit` remains an
    /// explicit full-range 420f control for A/B measurements.
    static func configuredPixelFormat(defaults: UserDefaults = .standard) -> OSType {
        switch defaults.string(forKey: "SideScreen_exp_pixelFormat") {
        case "10bit":
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case "8bitVideo", nil:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        default:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    private static func observation(from sampleBuffer: CMSampleBuffer) -> Observation {
        guard let attachments =
                (CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                ) as? [[SCStreamFrameInfo: Any]])?.first else {
            // Metadata unavailable: preserve quality rather than guessing idle.
            return Observation(isIdle: false, dirtyRatio: 1)
        }

        let statusRaw: Int? = {
            if let value = attachments[.status] as? Int { return value }
            if let value = attachments[.status] as? NSNumber { return value.intValue }
            return nil
        }()
        let status = statusRaw.flatMap { SCFrameStatus(rawValue: $0) }
        let isIdle = status == .idle

        if isIdle {
            return Observation(isIdle: true, dirtyRatio: 0)
        }

        let rects = decodeDirtyRects(attachments[.dirtyRects])

        // SCStreamFrameInfo.dirtyRects is expressed in output pixels. Use the
        // pixel buffer's physical dimensions as the denominator when possible;
        // contentRect may be expressed in points and would overstate motion on
        // HiDPI captures if mixed with pixel-space dirty rectangles.
        let frameArea: Double = {
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                return Double(CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer))
            }
            if let rect = decodeRect(attachments[.contentRect]),
               rect.width > 0, rect.height > 0 {
                return Double(rect.width * rect.height)
            }
            return Double(max(1, widthFallback(sampleBuffer)) * max(1, heightFallback(sampleBuffer)))
        }()

        guard !rects.isEmpty, frameArea > 0 else {
            // If a framework/OS version omits dirty rects, stay conservative:
            // treat the frame as broad motion so adaptive refresh cannot hurt
            // visual correctness.
            return Observation(isIdle: false, dirtyRatio: 1)
        }

        let dirtyArea = rects.reduce(0.0) { partial, rect in
            partial + Double(max(0, rect.width) * max(0, rect.height))
        }
        return Observation(isIdle: false, dirtyRatio: min(max(dirtyArea / frameArea, 0), 1))
    }

    /// ScreenCaptureKit has represented CGRect metadata differently across
    /// framework/bridging layers: Swift CGRects, NSValues, and CoreGraphics
    /// dictionary representations are all seen in the wild. Accept all three
    /// so a valid tiny dirty region never falls through to the conservative
    /// "whole frame changed" path.
    private static func decodeDirtyRects(_ value: Any?) -> [CGRect] {
        guard let value else { return [] }

        if let rects = value as? [CGRect] {
            return rects
        }
        if let values = value as? [NSValue] {
            return values.map { $0.rectValue }
        }
        if let array = value as? NSArray {
            return array.compactMap { decodeRect($0) }
        }
        return []
    }

    private static func decodeRect(_ value: Any?) -> CGRect? {
        guard let value else { return nil }
        if let rect = value as? CGRect {
            return rect
        }
        if let boxed = value as? NSValue {
            return boxed.rectValue
        }
        if let dictionary = value as? NSDictionary {
            var rect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &rect) {
                return rect
            }
        }
        return nil
    }

    private static func widthFallback(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return 1 }
        return Int(CMVideoFormatDescriptionGetDimensions(format).width)
    }

    private static func heightFallback(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return 1 }
        return Int(CMVideoFormatDescriptionGetDimensions(format).height)
    }
}
