package com.sidescreen.app

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Window
import android.view.WindowManager

/** Pure decision used by the transactional brightness owner and its tests. */
object BrightnessRestorationPolicy {
    fun shouldRestoreSystem(
        snapshotMode: Int?,
        snapshotValue: Int?,
        currentMode: Int?,
        currentValue: Int?,
        lastAppliedValue: Int?,
    ): Boolean =
        snapshotMode != null &&
            snapshotValue != null &&
            currentMode == Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL &&
            currentValue != null &&
            currentValue == lastAppliedValue

    fun shouldRestoreWindow(
        currentValue: Float,
        lastAppliedValue: Float?,
    ): Boolean =
        lastAppliedValue != null &&
            java.lang.Float.floatToIntBits(currentValue) ==
                java.lang.Float.floatToIntBits(lastAppliedValue)
}

/**
 * Owns the tablet's brightness only for one authoritative streaming
 * generation.  System settings are snapshotted before the first mutation;
 * teardown restores them only when the current value still matches SideScreen
 * last write, so an independent user change wins.
 */
class BrightnessOwnershipController(
    context: Context,
    private val windowProvider: () -> Window,
) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()

    private data class Snapshot(
        val mode: Int?,
        val value: Int?,
        val windowValue: Float,
    )

    @Volatile private var ownerGeneration: Long? = null
    private var snapshot: Snapshot? = null
    private var lastAppliedSystemValue: Int? = null
    private var lastAppliedWindowValue: Float? = null
    private var observer: ContentObserver? = null

    fun acquire(generation: Long) {
        synchronized(lock) {
            if (ownerGeneration == generation) return
            releaseLocked(ownerGeneration)
            val attributes = windowProvider().attributes
            snapshot = Snapshot(
                mode = readInt(Settings.System.SCREEN_BRIGHTNESS_MODE),
                value = readInt(Settings.System.SCREEN_BRIGHTNESS),
                windowValue = attributes.screenBrightness,
            )
            ownerGeneration = generation
            lastAppliedSystemValue = null
            lastAppliedWindowValue = null
            installObserverLocked()
            DiagLog.log(
                "BRT",
                "brightness ownership acquired generation=$generation " +
                    "mode=${snapshot?.mode} value=${snapshot?.value} " +
                    "window=${snapshot?.windowValue}",
            )
        }
    }

    fun apply(generation: Long, value: Int) {
        val v = value.coerceIn(0, 255)
        synchronized(lock) {
            if (ownerGeneration != generation) {
                DiagLog.log("BRT", "ignored stale brightness value=$v generation=$generation")
                return
            }
        }

        var wroteSystem = false
        val canWriteSystem = runCatching { Settings.System.canWrite(appContext) }.getOrDefault(false)
        if (canWriteSystem) {
            try {
                val modeWritten = Settings.System.putInt(
                    resolver,
                    Settings.System.SCREEN_BRIGHTNESS_MODE,
                    Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
                )
                val valueWritten = Settings.System.putInt(
                    resolver,
                    Settings.System.SCREEN_BRIGHTNESS,
                    v,
                )
                wroteSystem = modeWritten && valueWritten
                if (wroteSystem) {
                    synchronized(lock) { lastAppliedSystemValue = v }
                    DiagLog.log("BRT", "system backlight applied value=$v generation=$generation")
                } else {
                    DiagLog.log("BRT", "system brightness write rejected for value=$v")
                }
            } catch (e: Exception) {
                DiagLog.log("BRT", "system backlight failed: ${e.message}")
            }
        } else {
            DiagLog.log("BRT", "WRITE_SETTINGS unavailable — using transactional window fallback")
        }

        if (!wroteSystem) {
            val windowBrightness = (v / 255f).coerceIn(0.02f, 1f)
            synchronized(lock) { lastAppliedWindowValue = windowBrightness }
            mainHandler.post {
                synchronized(lock) {
                    if (ownerGeneration != generation) return@synchronized
                }
                runCatching {
                    val window = windowProvider()
                    val attributes = window.attributes
                    attributes.screenBrightness = windowBrightness
                    window.attributes = attributes
                    DiagLog.log("BRT", "window brightness fallback $windowBrightness value=$v generation=$generation")
                }.onFailure { error ->
                    DiagLog.log("BRT", "window brightness failed: ${error.message}")
                }
            }
        }
    }

    fun release(generation: Long? = null) {
        synchronized(lock) {
            if (generation != null && ownerGeneration != generation) return
            releaseLocked(ownerGeneration)
        }
    }

    fun isOwner(generation: Long): Boolean = ownerGeneration == generation

    private fun releaseLocked(releasingGeneration: Long?) {
        if (releasingGeneration == null) return
        val saved = snapshot
        val appliedSystem = lastAppliedSystemValue
        val appliedWindow = lastAppliedWindowValue
        observer?.let { resolver.unregisterContentObserver(it) }
        observer = null

        if (saved != null && appliedSystem != null) {
            val currentMode = readInt(Settings.System.SCREEN_BRIGHTNESS_MODE)
            val currentValue = readInt(Settings.System.SCREEN_BRIGHTNESS)
            if (BrightnessRestorationPolicy.shouldRestoreSystem(
                    saved.mode,
                    saved.value,
                    currentMode,
                    currentValue,
                    appliedSystem,
                )
            ) {
                runCatching {
                    saved.mode?.let {
                        Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS_MODE, it)
                    }
                    saved.value?.let {
                        Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, it)
                    }
                    DiagLog.log("BRT", "system brightness ownership released generation=$releasingGeneration")
                }.onFailure { error ->
                    DiagLog.log("BRT", "system brightness restore failed: ${error.message}")
                }
            } else {
                DiagLog.log("BRT", "user brightness change detected — preserving newer system value")
            }
        }

        if (saved != null && appliedWindow != null) {
            mainHandler.post {
                runCatching {
                    // A new stream may have acquired ownership before this
                    // main-thread restore runs. The old generation must not
                    // put its snapshot over the new owner's window value.
                    synchronized(lock) {
                        if (ownerGeneration != null) return@runCatching
                    }
                    val window = windowProvider()
                    val current = window.attributes.screenBrightness
                    if (BrightnessRestorationPolicy.shouldRestoreWindow(current, appliedWindow)) {
                        val attributes = window.attributes
                        attributes.screenBrightness = saved.windowValue
                        window.attributes = attributes
                        DiagLog.log("BRT", "window brightness restored generation=$releasingGeneration")
                    }
                }.onFailure { error ->
                    DiagLog.log("BRT", "window brightness restore failed: ${error.message}")
                }
            }
        }

        ownerGeneration = null
        snapshot = null
        lastAppliedSystemValue = null
        lastAppliedWindowValue = null
    }

    private fun installObserverLocked() {
        val contentObserver = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean) {
                // The owner compares the current settings with its last write
                // at release. This observer is intentionally diagnostic only:
                // it prevents an input change from being mistaken for a
                // transport event and avoids fighting the user in a loop.
                DiagLog.log("BRT", "system brightness changed while SideScreen owns generation=$ownerGeneration")
            }
        }
        observer = contentObserver
        resolver.registerContentObserver(Settings.System.getUriFor(Settings.System.SCREEN_BRIGHTNESS), false, contentObserver)
        resolver.registerContentObserver(Settings.System.getUriFor(Settings.System.SCREEN_BRIGHTNESS_MODE), false, contentObserver)
    }

    private fun readInt(name: String): Int? =
        runCatching { Settings.System.getInt(resolver, name) }.getOrNull()
}
