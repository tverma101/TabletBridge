import Foundation

/// Metadata carried with one encoded frame from capture admission through the
/// host send-completion callback. All timestamps are monotonic uptime
/// nanoseconds from DispatchTime.
struct EncodedVideoFrame {
    let frameID: UInt64
    /// WindowServer display time when ScreenCaptureKit provided it; otherwise
    /// the callback monotonic time is used as an explicitly marked fallback.
    let captureTimestampNs: UInt64
    /// ScreenCaptureKit callback receipt time, kept separate from the source
    /// display timestamp so delivery delay is visible in diagnostics.
    let screenCaptureCallbackTimestampNs: UInt64
    let encodeStartTimestampNs: UInt64
    let encodeCompleteTimestampNs: UInt64
    let data: Data
    let isKeyframe: Bool
}

struct FrameBackpressureLimits: Equatable {
    let maxInFlightFrames: Int
    let maxInFlightBytes: Int
    let estimatedFrameBytes: Int

    /// Conservative USB/wireless sender-side credit. The actual byte limit is
    /// enforced using the encoded packet size; this estimate only prevents the
    /// capture path from starting work when the sender is already nearly full.
    static let `default` = FrameBackpressureLimits(
        maxInFlightFrames: 3,
        maxInFlightBytes: 8 * 1024 * 1024,
        estimatedFrameBytes: 512 * 1024
    )
}

struct FrameBackpressureSnapshot: Equatable {
    let inFlightFrames: Int
    let inFlightBytes: Int
    let awaitingSyncFrame: Bool
    let preEncodeDrops: UInt64
    let sendAdmissionDrops: UInt64
    let syncDrops: UInt64
    let completedFrames: UInt64
}

enum FrameAdmissionResult {
    case admitted(FrameReservation)
    case waitingForSync
    case overloaded
}

struct FrameReservation {
    fileprivate let bytes: Int
    fileprivate let generation: UInt64
}

/// Thread-safe bounded sender admission. A reservation is made before a
/// frame-queue task is enqueued, so the GCD queue itself cannot grow with the
/// capture cadence. Overload intentionally enters a sync-frame gate: dropping
/// an already-encoded P-frame would otherwise break the HEVC/H.264 dependency
/// chain for every later frame in that GOP.
final class FrameBackpressureController {
    let limits: FrameBackpressureLimits

    private struct State {
        var generation: UInt64 = 0
        var inFlightFrames = 0
        var inFlightBytes = 0
        var awaitingSyncFrame = true
        var preEncodeDrops: UInt64 = 0
        var sendAdmissionDrops: UInt64 = 0
        var syncDrops: UInt64 = 0
        var completedFrames: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = State()

    init(limits: FrameBackpressureLimits = .default) {
        self.limits = limits
    }

    func canAdmitNextFrame(estimatedBytes: Int? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let bytes = max(estimatedBytes ?? limits.estimatedFrameBytes, 1)
        return state.inFlightFrames < limits.maxInFlightFrames
            && state.inFlightBytes + bytes <= limits.maxInFlightBytes
    }

    func recordPreEncodeDrop() {
        lock.lock()
        state.preEncodeDrops &+= 1
        lock.unlock()
    }

    func reserve(bytes: Int, isKeyframe: Bool) -> FrameAdmissionResult {
        let boundedBytes = max(bytes, 1)
        lock.lock()
        defer { lock.unlock() }

        if state.awaitingSyncFrame && !isKeyframe {
            state.syncDrops &+= 1
            return .waitingForSync
        }

        guard boundedBytes <= limits.maxInFlightBytes,
              state.inFlightFrames < limits.maxInFlightFrames,
              state.inFlightBytes + boundedBytes <= limits.maxInFlightBytes else {
            state.awaitingSyncFrame = true
            state.sendAdmissionDrops &+= 1
            return .overloaded
        }

        let reservation = FrameReservation(bytes: boundedBytes, generation: state.generation)
        state.inFlightFrames += 1
        state.inFlightBytes += boundedBytes
        if isKeyframe {
            state.awaitingSyncFrame = false
        }
        return .admitted(reservation)
    }

    func markNeedsSyncFrame() {
        lock.lock()
        state.awaitingSyncFrame = true
        lock.unlock()
    }

    func complete(_ reservation: FrameReservation) {
        lock.lock()
        defer { lock.unlock() }
        guard reservation.generation == state.generation else { return }
        state.inFlightFrames = max(0, state.inFlightFrames - 1)
        state.inFlightBytes = max(0, state.inFlightBytes - reservation.bytes)
        state.completedFrames &+= 1
    }

    func snapshot() -> FrameBackpressureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FrameBackpressureSnapshot(
            inFlightFrames: state.inFlightFrames,
            inFlightBytes: state.inFlightBytes,
            awaitingSyncFrame: state.awaitingSyncFrame,
            preEncodeDrops: state.preEncodeDrops,
            sendAdmissionDrops: state.sendAdmissionDrops,
            syncDrops: state.syncDrops,
            completedFrames: state.completedFrames
        )
    }

    func resetIntervalCounters() {
        lock.lock()
        state.preEncodeDrops = 0
        state.sendAdmissionDrops = 0
        state.syncDrops = 0
        state.completedFrames = 0
        lock.unlock()
    }

    func resetForNewSession() {
        lock.lock()
        state.generation &+= 1
        state.inFlightFrames = 0
        state.inFlightBytes = 0
        state.awaitingSyncFrame = true
        state.preEncodeDrops = 0
        state.sendAdmissionDrops = 0
        state.syncDrops = 0
        state.completedFrames = 0
        lock.unlock()
    }
}

struct LatencyPercentileSummary: Equatable {
    let count: Int
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double
}

/// Small bounded percentile window for runtime diagnostics. The backing store
/// is a fixed-size circular buffer so steady-state frame accounting never
/// shifts an Array with removeFirst() on the 60/120-FPS send path.
struct LatencyPercentiles {
    private let maxSamples: Int
    private var samples: [Double]
    private var sampleCount = 0
    private var nextSampleIndex = 0

    init(maxSamples: Int = 240) {
        self.maxSamples = max(1, maxSamples)
        self.samples = Array(repeating: 0.0, count: self.maxSamples)
    }

    var count: Int { sampleCount }

    mutating func add(nanoseconds: UInt64) {
        samples[nextSampleIndex] = Double(nanoseconds) / 1_000_000.0
        nextSampleIndex += 1
        if nextSampleIndex == maxSamples {
            nextSampleIndex = 0
        }
        if sampleCount < maxSamples {
            sampleCount += 1
        }
    }

    mutating func removeAll() {
        sampleCount = 0
        nextSampleIndex = 0
    }

    func summary() -> LatencyPercentileSummary? {
        guard sampleCount > 0 else { return nil }
        // Ordering in the ring is irrelevant for percentiles. Copy/sort only
        // when a summary is requested (roughly once per second), never per frame.
        let sorted = samples.prefix(sampleCount).sorted()
        return LatencyPercentileSummary(
            count: sorted.count,
            p50Ms: percentile(sorted, fraction: 0.50),
            p95Ms: percentile(sorted, fraction: 0.95),
            p99Ms: percentile(sorted, fraction: 0.99),
            maxMs: sorted[sorted.count - 1]
        )
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let index = min(sorted.count - 1, max(0, Int(ceil(fraction * Double(sorted.count))) - 1))
        return sorted[index]
    }
}
