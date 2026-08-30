import XCTest
@testable import SideScreen

final class FramePipelineTests: XCTestCase {
    func testBackpressureRequiresSyncFrameAndBoundsFramesAndBytes() {
        let controller = FrameBackpressureController(
            limits: FrameBackpressureLimits(
                maxInFlightFrames: 2,
                maxInFlightBytes: 100,
                estimatedFrameBytes: 40
            )
        )

        guard case .waitingForSync = controller.reserve(bytes: 20, isKeyframe: false) else {
            return XCTFail("a new session must reject P-frames until an IDR is admitted")
        }
        guard case .admitted(let first) = controller.reserve(bytes: 60, isKeyframe: true) else {
            return XCTFail("the first keyframe should be admitted")
        }
        guard case .admitted(let second) = controller.reserve(bytes: 40, isKeyframe: false) else {
            return XCTFail("the second frame should fit the explicit byte/frame budget")
        }
        guard case .overloaded = controller.reserve(bytes: 1, isKeyframe: false) else {
            return XCTFail("the third in-flight frame must be rejected")
        }

        let snapshot = controller.snapshot()
        XCTAssertEqual(snapshot.inFlightFrames, 2)
        XCTAssertEqual(snapshot.inFlightBytes, 100)
        XCTAssertTrue(snapshot.awaitingSyncFrame)
        XCTAssertEqual(snapshot.sendAdmissionDrops, 1)

        controller.complete(first)
        controller.complete(second)
        XCTAssertEqual(controller.snapshot().inFlightFrames, 0)
    }

    func testLatencyWindowReportsP95AndP99FromBoundedSamples() throws {
        var window = LatencyPercentiles(maxSamples: 4)
        for milliseconds in 1...4 {
            window.add(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }

        let summary = try XCTUnwrap(window.summary())
        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.p50Ms, 2, accuracy: 0.001)
        XCTAssertEqual(summary.p95Ms, 4, accuracy: 0.001)
        XCTAssertEqual(summary.p99Ms, 4, accuracy: 0.001)
        XCTAssertEqual(summary.maxMs, 4, accuracy: 0.001)
    }
}
