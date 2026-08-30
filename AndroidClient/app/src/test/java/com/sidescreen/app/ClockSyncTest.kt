package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClockSyncTest {
    @Test
    fun translatesMacTimestampBySubtractingMacAheadOffset() {
        assertEquals(
            1_995_000_000L,
            translateMacTimestampToAndroid(2_000_000_000L, 5_000_000L),
        )
    }

    @Test
    fun estimatesMacAheadOffsetFromNtpQuartet() {
        val estimator = ClockOffsetEstimator()
        val sample = estimator.addSample(
            androidSendNs = 1_000_000_000L,
            macReceiveNs = 1_006_000_000L,
            macSendNs = 1_006_100_000L,
            androidReceiveNs = 1_002_100_000L,
        )

        assertTrue(sample.accepted)
        assertEquals(5_000_000L, sample.offsetNs)
        assertEquals(2_000_000L, sample.rttNs)
    }

    @Test
    fun rejectsHighRttWithoutMovingExistingEstimate() {
        val estimator = ClockOffsetEstimator()
        estimator.addSample(1_000_000_000L, 1_006_000_000L, 1_006_100_000L, 1_002_100_000L)

        val outlier = estimator.addSample(
            androidSendNs = 2_000_000_000L,
            macReceiveNs = 2_100_000_000L,
            macSendNs = 2_100_100_000L,
            androidReceiveNs = 2_500_100_000L,
        )

        assertFalse(outlier.accepted)
        assertEquals(5_000_000L, estimator.currentOffsetOrNull())
    }
}
