package com.sidescreen.app

/**
 * Render-thread cadence helper for experimental presentation paths.
 *
 * A cap belongs at the presentation boundary: the renderer can still drain to
 * the newest decoded frame instead of building a queue, while the display
 * never receives more than the requested cadence. The class is deliberately
 * clock-only so its schedule can be tested without an EGL context.
 */
internal class FramePacer(targetFps: Int?) {
    val targetFps: Int? = targetFps?.takeIf { it > 0 }?.coerceAtMost(240)

    private val intervalNs: Long? = this.targetFps?.let { 1_000_000_000L / it }
    private var nextSlotNs = 0L

    /** How long the render thread should wait before starting the next pass. */
    fun delayNanos(nowNs: Long): Long {
        if (intervalNs == null || nextSlotNs == 0L) return 0L
        return (nextSlotNs - nowNs).coerceAtLeast(0L)
    }

    /** Mark the start of a render slot and advance the cadence without drift. */
    fun markSlotStarted(nowNs: Long) {
        val interval = intervalNs ?: return
        val scheduled = if (nextSlotNs == 0L) nowNs else nextSlotNs
        val nextScheduled = scheduled + interval
        // If the renderer is already late, restart from now plus one interval;
        // otherwise a missed slot would permit two presentation calls together.
        nextSlotNs = if (nextScheduled > nowNs) nextScheduled else nowNs + interval
    }
}
