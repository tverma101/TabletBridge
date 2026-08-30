package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class WirelessTransportProfileTest {
    @Test
    fun wirelessSessionUsesSixtyFps() {
        assertEquals(60, WirelessTransportProfile.TARGET_FPS)
    }

    @Test
    fun videoBuffersAreBoundedForBurstTolerance() {
        assertEquals(1024 * 1024, WirelessTransportProfile.VIDEO_SOCKET_RECEIVE_BUFFER_BYTES)
        assertEquals(256 * 1024, WirelessTransportProfile.VIDEO_STREAM_BUFFER_BYTES)
    }
}
