import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Same-display source benchmark used by the live macOS capture investigation.
/// It deliberately lives in the signed host binary so Screen Recording is
/// evaluated under the canonical Tablet Bridge identity rather than an ad-hoc
/// helper bundle with a different TCC grant.
enum CaptureSourceBenchmark {
    private struct Options {
        let displayID: CGDirectDisplayID
        let duration: TimeInterval
    }

    private struct Result {
        let source: String
        let callbacks: Int
        let nonEmptyFrames: Int
        let elapsed: TimeInterval
        let error: String?

        var callbackFPS: Double {
            guard elapsed > 0 else { return 0 }
            return Double(callbacks) / elapsed
        }
    }

    private final class Stats {
        private let lock = NSLock()
        private var callbackCount = 0
        private var nonEmptyFrameCount = 0

        func record(nonEmpty: Bool) {
            lock.lock()
            callbackCount += 1
            if nonEmpty {
                nonEmptyFrameCount += 1
            }
            lock.unlock()
        }

        func snapshot() -> (callbacks: Int, nonEmptyFrames: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (callbackCount, nonEmptyFrameCount)
        }
    }

    private final class ErrorBox {
        private let lock = NSLock()
        private var value: String?

        func set(_ error: Error) {
            lock.lock()
            value = error.localizedDescription
            lock.unlock()
        }

        func set(_ message: String) {
            lock.lock()
            value = message
            lock.unlock()
        }

        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
        let stats: Stats
        let error: ErrorBox

        init(stats: Stats, error: ErrorBox) {
            self.stats = stats
            self.error = error
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen else { return }
            stats.record(nonEmpty: CMSampleBufferGetImageBuffer(sampleBuffer) != nil)
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            self.error.set(error)
        }
    }

    /// Returns true when the process was invoked in benchmark mode. The
    /// normal application path is unchanged when no benchmark flag is given.
    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.contains("--capture-source-benchmark") else {
            return false
        }

        let options: Options
        do {
            options = try parse(arguments: arguments)
        } catch {
            print("Capture benchmark error: \(error.localizedDescription)")
            exit(2)
        }

        let durationText = String(format: "%.1f", options.duration)
        let modeDescription = "display=\(options.displayID) duration=\(durationText)s"
        let size = CGDisplayCopyDisplayMode(options.displayID).map {
            "\($0.pixelWidth)x\($0.pixelHeight)"
        } ?? "unknown"
        emit("Capture source benchmark: \(modeDescription) size=\(size)")
        emit("This process uses the canonical Tablet Bridge bundle identity for TCC.")

        let cg = runCGDisplayStream(displayID: options.displayID, duration: options.duration)
        printResult(cg)

        let sc = runScreenCaptureKit(displayID: options.displayID, duration: options.duration)
        printResult(sc)

        exit((cg.error == nil && sc.error == nil) ? 0 : 1)
    }

    private static func parse(arguments: [String]) throws -> Options {
        guard let displayIndex = arguments.firstIndex(of: "--display-id"),
              displayIndex + 1 < arguments.count,
              let rawDisplayID = UInt32(arguments[displayIndex + 1])
        else {
            throw NSError(
                domain: "CaptureSourceBenchmark",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Use --display-id <id> with --capture-source-benchmark"]
            )
        }

        let duration: TimeInterval
        if let durationIndex = arguments.firstIndex(of: "--duration"),
           durationIndex + 1 < arguments.count,
           let rawDuration = Double(arguments[durationIndex + 1]) {
            duration = min(max(rawDuration, 1), 60)
        } else {
            duration = 10
        }

        guard CGDisplayIsOnline(rawDisplayID) != 0 else {
            throw NSError(
                domain: "CaptureSourceBenchmark",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display \(rawDisplayID) is not online"]
            )
        }
        return Options(displayID: rawDisplayID, duration: duration)
    }

    private static func runCGDisplayStream(
        displayID: CGDirectDisplayID,
        duration: TimeInterval
    ) -> Result {
        let start = CFAbsoluteTimeGetCurrent()
        let stats = Stats()
        let error = ErrorBox()
        let width = max(1, CGDisplayPixelsWide(displayID))
        let height = max(1, CGDisplayPixelsHigh(displayID))
        let queue = DispatchQueue(label: "dev.tabletbridge.capture-benchmark.cg", qos: .userInteractive)

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: nil,
            queue: queue,
            handler: { _, _, surface, _ in
                stats.record(nonEmpty: surface != nil)
            }
        ) else {
            return Result(
                source: "CGDisplayStream",
                callbacks: 0,
                nonEmptyFrames: 0,
                elapsed: CFAbsoluteTimeGetCurrent() - start,
                error: "create returned nil"
            )
        }

        guard stream.start() == .success else {
            stream.stop()
            return Result(
                source: "CGDisplayStream",
                callbacks: 0,
                nonEmptyFrames: 0,
                elapsed: CFAbsoluteTimeGetCurrent() - start,
                error: "start failed"
            )
        }

        Thread.sleep(forTimeInterval: duration)
        stream.stop()
        let snapshot = stats.snapshot()
        return Result(
            source: "CGDisplayStream",
            callbacks: snapshot.callbacks,
            nonEmptyFrames: snapshot.nonEmptyFrames,
            elapsed: CFAbsoluteTimeGetCurrent() - start,
            error: error.get()
        )
    }

    private static func runScreenCaptureKit(
        displayID: CGDirectDisplayID,
        duration: TimeInterval
    ) -> Result {
        let box = ErrorBox()
        let resultBox = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let start = CFAbsoluteTimeGetCurrent()

        Task {
            let stats = Stats()
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw NSError(
                        domain: "CaptureSourceBenchmark",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Display not present in SCShareableContent"]
                    )
                }

                let output = StreamOutput(stats: stats, error: box)
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 3
                config.capturesAudio = false
                config.showsCursor = true

                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "dev.tabletbridge.capture-benchmark.sc", qos: .userInteractive)
                )
                try await stream.startCapture()
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                try await stream.stopCapture()

                let snapshot = stats.snapshot()
                resultBox.set(Result(
                    source: "ScreenCaptureKit",
                    callbacks: snapshot.callbacks,
                    nonEmptyFrames: snapshot.nonEmptyFrames,
                    elapsed: CFAbsoluteTimeGetCurrent() - start,
                    error: box.get()
                ))
            } catch {
                box.set(error)
                let snapshot = stats.snapshot()
                resultBox.set(Result(
                    source: "ScreenCaptureKit",
                    callbacks: snapshot.callbacks,
                    nonEmptyFrames: snapshot.nonEmptyFrames,
                    elapsed: CFAbsoluteTimeGetCurrent() - start,
                    error: error.localizedDescription
                ))
            }
            done.signal()
        }

        _ = done.wait(timeout: .now() + duration + 15)
        return resultBox.get() ?? Result(
            source: "ScreenCaptureKit",
            callbacks: 0,
            nonEmptyFrames: 0,
            elapsed: CFAbsoluteTimeGetCurrent() - start,
            error: "benchmark timed out"
        )
    }

    private final class ResultBox {
        private let lock = NSLock()
        private var value: Result?

        func set(_ result: Result) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func get() -> Result? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func printResult(_ result: Result) {
        let status = result.error == nil ? "PASS" : "FAIL"
        let errorText = result.error.map { " error=\($0)" } ?? ""
        emit(
            String(
                format: "source=%@ status=%@ callbacks=%d nonEmpty=%d callbackFPS=%.2f elapsed=%.2fs%@",
                result.source,
                status,
                result.callbacks,
                result.nonEmptyFrames,
                result.callbackFPS,
                result.elapsed,
                errorText
            )
        )
    }

    private static func emit(_ message: String) {
        print(message)
        debugLog("capture-source-benchmark: \(message)")
    }
}
