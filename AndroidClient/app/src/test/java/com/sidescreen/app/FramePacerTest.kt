package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FramePacerTest {
    @Test
    fun uncappedPathNeverAddsDelay() {
        val pacer = FramePacer(null)

        assertEquals(0L, pacer.delayNanos(1_000_000_000L))
        pacer.markSlotStarted(1_000_000_000L)
        assertEquals(0L, pacer.delayNanos(1_000_000_001L))
    }

    @Test
    fun sixtyFpsPathSchedulesSixteenPointSixMillisecondSlots() {
        val pacer = FramePacer(60)
        val first = 1_000_000_000L

        pacer.markSlotStarted(first)

        assertEquals(16_666_666L, pacer.delayNanos(first))
        assertEquals(0L, pacer.delayNanos(first + 16_666_666L))
        pacer.markSlotStarted(first + 16_666_666L)
        assertTrue(pacer.delayNanos(first + 16_666_667L) > 16_000_000L)
    }

    @Test
    fun lateRenderDoesNotCreateAnImmediateBurst() {
        val pacer = FramePacer(60)
        val first = 1_000_000_000L

        pacer.markSlotStarted(first)
        // A render pass that misses its scheduled slot should restart from
        // the current clock, rather than issuing two swaps back-to-back.
        pacer.markSlotStarted(first + 40_000_000L)

        assertEquals(16_666_666L, pacer.delayNanos(first + 40_000_000L))
    }
}
