package com.sidescreen.app

import android.provider.Settings
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BrightnessOwnershipControllerTest {
    @Test
    fun restoresSystemOnlyWhenSideScreenStillOwnsLastValue() {
        assertTrue(
            BrightnessRestorationPolicy.shouldRestoreSystem(
                snapshotMode = Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC,
                snapshotValue = 80,
                currentMode = Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
                currentValue = 160,
                lastAppliedValue = 160,
            ),
        )
        assertFalse(
            BrightnessRestorationPolicy.shouldRestoreSystem(
                snapshotMode = Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC,
                snapshotValue = 80,
                currentMode = Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
                currentValue = 100,
                lastAppliedValue = 160,
            ),
        )
    }

    @Test
    fun restoresWindowOverrideOnlyWhenUserDidNotRetargetIt() {
        assertTrue(BrightnessRestorationPolicy.shouldRestoreWindow(0.4f, 0.4f))
        assertFalse(BrightnessRestorationPolicy.shouldRestoreWindow(0.7f, 0.4f))
    }
}
