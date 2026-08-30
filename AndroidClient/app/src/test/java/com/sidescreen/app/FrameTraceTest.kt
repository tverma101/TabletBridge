package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class FrameTraceTest {
    @Test
    fun visibleLatencyWindowReportsPercentiles() {
        val stats = FrameTraceStats(maxSamples = 4)
        for (i in 1L..4L) {
            stats.add(
                FrameTrace(
                    frameId = i,
                    hostCaptureNs = i,
                    captureNs = 1_000_000_000L,
                    receivedNs = 1_000_000_000L,
                    surfaceRenderedNs = 1_000_000_000L + i * 1_000_000L,
                ),
            )
        }

        val summary = stats.summary()
        assertNotNull(summary)
        assertEquals(4, summary?.count)
        assertEquals(2.0, summary?.p50Ms ?: 0.0, 0.001)
        assertEquals(4.0, summary?.p99Ms ?: 0.0, 0.001)
        assertEquals(4.0, summary?.maxMs ?: 0.0, 0.001)
    }

    @Test
    fun pacingSummaryExposesCadenceAndFrameIdGaps() {
        val stats = FrameTraceStats(maxSamples = 8)
        val renderTimes = listOf(0L, 16_666_666L, 33_333_332L, 66_666_664L)
        val frameIds = listOf(1L, 2L, 2L, 4L)
        renderTimes.zip(frameIds).forEach { (offset, frameId) ->
            stats.add(
                FrameTrace(
                    frameId = frameId,
                    hostCaptureNs = 1L,
                    captureNs = 1_000_000_000L,
                    receivedNs = 1_000_000_000L,
                    surfaceRenderedNs = 1_000_000_000L + offset,
                ),
            )
        }

        val summary = stats.pacingSummary()
        assertNotNull(summary)
        assertEquals(3, summary?.count)
        assertEquals(45.0, summary?.renderedFps ?: 0.0, 0.01)
        assertEquals(1L, summary?.duplicateFrames)
        assertEquals(1L, summary?.skippedFrames)
        assertEquals(0L, summary?.reorderedFrames)
        assertEquals(33.333, summary?.maxMs ?: 0.0, 0.001)
    }
}
