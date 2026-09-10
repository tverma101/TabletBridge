package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidColorProfileTest {
    @Test
    fun usbProfileIsOptionalAndKeepsTheMeasuredNeutralAnchoredToneCurve() {
        // Wired efficiency default: direct MediaCodec -> Surface. The measured
        // calibration remains intact and can still be enabled explicitly.
        assertFalse(AndroidColorProfile.DEFAULT_ENABLED)
        assertTrue(AndroidColorProfile.GLSL_FUNCTION.contains("55.0 / 255.0"))
        assertTrue(AndroidColorProfile.GLSL_FUNCTION.contains("130.0 / 255.0"))
        assertTrue(AndroidColorProfile.GLSL_FUNCTION.contains("204.0 / 255.0"))
        assertTrue(AndroidColorProfile.GLSL_FUNCTION.contains("64.0 / 255.0"))
        assertFalse(AndroidColorProfile.GLSL_FUNCTION.contains("1.0313543 * cb"))
    }

    @Test
    fun bridgeKeepsTheExperimentAtSixtyFrames() {
        assertEquals(60, AndroidColorProfile.USB_BRIDGE_FPS_CAP)
    }
}
