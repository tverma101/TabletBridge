package com.sidescreen.app

import kotlin.math.abs

data class ClockSyncEstimate(
    /** Mac monotonic time = Android monotonic time + offsetNs. */
    val offsetNs: Long,
    val rttNs: Long,
    val sampleCount: Int,
    val accepted: Boolean,
)

/** Convert a Mac monotonic timestamp into Android's monotonic clock domain. */
internal fun translateMacTimestampToAndroid(
    macTimestampNs: Long,
    macAheadOffsetNs: Long,
): Long = macTimestampNs - macAheadOffsetNs

/**
 * Small NTP-style rolling estimator for the Mac/Android monotonic-clock
 * offset. High-RTT samples and large offset outliers are rejected so a Wi-Fi
 * burst cannot turn a valid capture timestamp into a bogus visible-latency
 * spike.
 */
class ClockOffsetEstimator(
    private val maxSamples: Int = 31,
    private val maxRttNs: Long = 250_000_000L,
    private val maxOffsetOutlierNs: Long = 10_000_000L,
) {
    private val offsets = ArrayDeque<Long>(maxSamples)
    private val rtts = ArrayDeque<Long>(maxSamples)

    @Synchronized
    fun addSample(
        androidSendNs: Long,
        macReceiveNs: Long,
        macSendNs: Long,
        androidReceiveNs: Long,
    ): ClockSyncEstimate {
        val serverProcessingNs = macSendNs - macReceiveNs
        val roundTripNs = (androidReceiveNs - androidSendNs) - serverProcessingNs
        val offsetNs = ((macReceiveNs - androidSendNs) + (macSendNs - androidReceiveNs)) / 2L

        if (roundTripNs < 0L || roundTripNs > maxRttNs) {
            return ClockSyncEstimate(currentOffset(), roundTripNs, offsets.size, accepted = false)
        }

        if (offsets.size >= 3 && abs(offsetNs - median(offsets)) > maxOffsetOutlierNs) {
            return ClockSyncEstimate(currentOffset(), roundTripNs, offsets.size, accepted = false)
        }

        if (offsets.size == maxSamples) offsets.removeFirst()
        if (rtts.size == maxSamples) rtts.removeFirst()
        offsets.addLast(offsetNs)
        rtts.addLast(roundTripNs)
        return ClockSyncEstimate(offsetNs = median(offsets), rttNs = roundTripNs, sampleCount = offsets.size, accepted = true)
    }

    @Synchronized
    fun currentOffsetOrNull(): Long? = offsets.takeIf { it.isNotEmpty() }?.let(::median)

    private fun currentOffset(): Long = offsets.takeIf { it.isNotEmpty() }?.let(::median) ?: 0L

    private fun median(values: Collection<Long>): Long {
        val sorted = values.sorted()
        return sorted[sorted.size / 2]
    }
}
