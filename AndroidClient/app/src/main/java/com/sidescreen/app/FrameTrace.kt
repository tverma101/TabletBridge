package com.sidescreen.app

data class FrameTrace(
    val frameId: Long,
    val hostCaptureNs: Long,
    /** Host capture timestamp translated into Android's monotonic domain. */
    val captureNs: Long,
    val receivedNs: Long,
    val inputQueuedNs: Long = 0L,
    val outputAvailableNs: Long = 0L,
    /** The request handed to MediaCodec to release the output to Surface. */
    val outputReleaseRequestedNs: Long = 0L,
    /** Supplied by MediaCodec.OnFrameRenderedListener when available. */
    val surfaceRenderedNs: Long = 0L,
)

data class FrameTraceSummary(
    val count: Int,
    val p50Ms: Double,
    val p95Ms: Double,
    val p99Ms: Double,
    val maxMs: Double,
)

/**
 * Presentation-cadence summary for the same bounded trace window.
 *
 * Average FPS is intentionally only one field here. Alternating short/long
 * presents can have the same average as a healthy stream, so the lab exports
 * the interval percentiles and frame-ID discontinuities as first-class data.
 */
data class FramePacingSummary(
    val count: Int,
    val renderedFps: Double,
    val p50Ms: Double,
    val p95Ms: Double,
    val p99Ms: Double,
    val maxMs: Double,
    val standardDeviationMs: Double,
    val medianAbsoluteDeviationMs: Double,
    val duplicateFrames: Long,
    val skippedFrames: Long,
    val reorderedFrames: Long,
)

/** Bounded visible-latency window used by the runtime diagnostic log. */
class FrameTraceStats(private val maxSamples: Int = 240) {
    private val captureToSurfaceRenderNs = ArrayDeque<Long>(maxSamples)
    private val renderIntervalsNs = ArrayDeque<Long>(maxSamples)
    private var lastSurfaceRenderedNs = 0L
    private var lastFrameId = 0L
    private var duplicateFrames = 0L
    private var skippedFrames = 0L
    private var reorderedFrames = 0L

    @Synchronized
    fun add(trace: FrameTrace) {
        if (trace.surfaceRenderedNs <= 0L) return
        if (trace.captureNs > 0L && trace.surfaceRenderedNs >= trace.captureNs) {
            if (captureToSurfaceRenderNs.size == maxSamples) captureToSurfaceRenderNs.removeFirst()
            captureToSurfaceRenderNs.addLast(trace.surfaceRenderedNs - trace.captureNs)
        }

        if (trace.surfaceRenderedNs > lastSurfaceRenderedNs) {
            if (lastSurfaceRenderedNs > 0L) {
                val interval = trace.surfaceRenderedNs - lastSurfaceRenderedNs
                if (renderIntervalsNs.size == maxSamples) renderIntervalsNs.removeFirst()
                renderIntervalsNs.addLast(interval)
            }
            lastSurfaceRenderedNs = trace.surfaceRenderedNs
        }

        // Frame IDs are supplied by the Mac encoder. A gap is evidence that
        // source frames were dropped/admission-rejected; a repeated or lower
        // ID is a receiver/ordering failure. ID 0 is the legacy/no-metadata
        // value and is deliberately excluded from this classification.
        if (trace.frameId > 0L) {
            if (lastFrameId > 0L) {
                when {
                    trace.frameId == lastFrameId -> duplicateFrames++
                    trace.frameId < lastFrameId -> reorderedFrames++
                    trace.frameId > lastFrameId + 1L ->
                        skippedFrames += trace.frameId - lastFrameId - 1L
                }
            }
            if (trace.frameId > lastFrameId) lastFrameId = trace.frameId
        }
    }

    @Synchronized
    fun summary(): FrameTraceSummary? {
        if (captureToSurfaceRenderNs.isEmpty()) return null
        val sorted = captureToSurfaceRenderNs.sorted()
        fun percentile(fraction: Double): Double {
            val index = (kotlin.math.ceil(fraction * sorted.size).toInt() - 1)
                .coerceIn(0, sorted.lastIndex)
            return sorted[index] / 1_000_000.0
        }
        return FrameTraceSummary(
            count = sorted.size,
            p50Ms = percentile(0.50),
            p95Ms = percentile(0.95),
            p99Ms = percentile(0.99),
            maxMs = sorted.last() / 1_000_000.0,
        )
    }

    @Synchronized
    fun pacingSummary(): FramePacingSummary? {
        if (renderIntervalsNs.isEmpty()) return null
        val sorted = renderIntervalsNs.sorted().map { it / 1_000_000.0 }
        val mean = sorted.average()
        val median = percentile(sorted, 0.50)
        val absoluteDeviations = sorted.map { kotlin.math.abs(it - median) }.sorted()
        val variance = sorted.map { value -> (value - mean) * (value - mean) }.average()
        return FramePacingSummary(
            count = sorted.size,
            renderedFps = if (mean > 0.0) 1000.0 / mean else 0.0,
            p50Ms = median,
            p95Ms = percentile(sorted, 0.95),
            p99Ms = percentile(sorted, 0.99),
            maxMs = sorted.last(),
            standardDeviationMs = kotlin.math.sqrt(variance),
            medianAbsoluteDeviationMs = percentile(absoluteDeviations, 0.50),
            duplicateFrames = duplicateFrames,
            skippedFrames = skippedFrames,
            reorderedFrames = reorderedFrames,
        )
    }

    private fun percentile(sorted: List<Double>, fraction: Double): Double {
        val index = (kotlin.math.ceil(fraction * sorted.size).toInt() - 1)
            .coerceIn(0, sorted.lastIndex)
        return sorted[index]
    }
}
