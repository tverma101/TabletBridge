package com.sidescreen.app

import android.app.Activity
import android.content.pm.ActivityInfo
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager

/**
 * Owns stream-only Android presentation state. The idle/control shell keeps
 * normal bars, rotation, brightness, and screen power behavior.
 */
class PresentationController(
    private val activity: Activity,
    private val brightness: BrightnessOwnershipController,
) {
    private var ownerGeneration: Long? = null
    private var pendingRotation = 0

    val isActive: Boolean
        get() = ownerGeneration != null

    fun setPendingRotation(rotation: Int) {
        pendingRotation = rotation
        ownerGeneration?.let { applyOrientation(rotation) }
    }

    fun acquire(generation: Long) {
        if (ownerGeneration == generation) return
        release()
        ownerGeneration = generation
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemBars()
        applyOrientation(pendingRotation)
        brightness.acquire(generation)
        DiagLog.log("MA", "presentation acquired generation=$generation")
    }

    fun release(generation: Long? = null) {
        if (generation != null && ownerGeneration != generation) return
        val oldGeneration = ownerGeneration ?: return
        ownerGeneration = null
        brightness.release(oldGeneration)
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        showSystemBars()
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
        DiagLog.log("MA", "presentation released generation=$oldGeneration")
    }

    fun suspendScreenAwake() {
        if (ownerGeneration != null) {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    fun restoreScreenAwakeIfOwned() {
        if (ownerGeneration != null) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    fun owns(generation: Long): Boolean = ownerGeneration == generation

    private fun applyOrientation(rotation: Int) {
        activity.requestedOrientation = when (rotation) {
            90 -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
            270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
            else -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.window.setDecorFitsSystemWindows(false)
            activity.window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            activity.window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                )
        }
    }

    private fun showSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.window.setDecorFitsSystemWindows(true)
            activity.window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
        } else {
            @Suppress("DEPRECATION")
            activity.window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }
}
