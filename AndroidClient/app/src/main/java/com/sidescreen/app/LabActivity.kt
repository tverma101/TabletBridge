package com.sidescreen.app

import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import java.io.File

/**
 * Native Android control renderer for the visual-quality lab.
 *
 * MainActivity starts this internal activity through the opt-in lab command.
 * It draws the exact corpus PNG into a SurfaceView and captures that actual
 * surface with PixelCopy, giving the comparison a native Android digital
 * reference without using a UI screenshot or panel photography.
 */
class LabActivity : Activity() {
    private lateinit var surfaceView: SurfaceView
    private var sourceBitmap: Bitmap? = null
    private var outputFile: File? = null
    private var didCapture = false
    private var captureAttempts = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        applyImmersiveFlags()

        val sourcePath = intent.getStringExtra(EXTRA_SOURCE_PATH)
            ?: File(filesDir, "lab/input.png").absolutePath
        val outputName = intent.getStringExtra(EXTRA_OUTPUT_NAME) ?: "native.png"
        sourceBitmap = BitmapFactory.decodeFile(sourcePath)
        outputFile = labFile(outputName)

        if (sourceBitmap == null) {
            DiagLog.log("LAB", "native capture failed: cannot decode $sourcePath")
            finish()
            return
        }

        surfaceView = SurfaceView(this)
        surfaceView.setBackgroundColor(android.graphics.Color.BLACK)
        setContentView(surfaceView)
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                drawAndCaptureWhenReady(holder)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                drawAndCaptureWhenReady(holder)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
        })
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyImmersiveFlags()
    }

    private fun applyImmersiveFlags() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            )
    }

    private fun drawAndCaptureWhenReady(holder: SurfaceHolder) {
        val bitmap = sourceBitmap ?: return
        if (!holder.surface.isValid || holder.surfaceFrame.width() <= 0 || holder.surfaceFrame.height() <= 0) {
            return
        }
        val width = holder.surfaceFrame.width()
        val height = holder.surfaceFrame.height()
        val canvas: Canvas = holder.lockCanvas() ?: return
        try {
            canvas.drawColor(android.graphics.Color.BLACK)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { isFilterBitmap = false }
            canvas.drawBitmap(bitmap, null, Rect(0, 0, width, height), paint)
        } finally {
            holder.unlockCanvasAndPost(canvas)
        }

        if (!didCapture) {
            mainHandler.postDelayed({ captureSurface(holder, width, height) }, 250L)
        }
    }

    private fun captureSurface(holder: SurfaceHolder, width: Int, height: Int) {
        if (didCapture || !holder.surface.isValid) return
        val output = outputFile ?: return
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        captureAttempts++
        PixelCopy.request(
            holder.surface,
            bitmap,
            { result ->
                if (result == PixelCopy.SUCCESS) {
                    runCatching {
                        output.parentFile?.mkdirs()
                        output.outputStream().use { stream ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                        }
                        didCapture = true
                        DiagLog.log(
                            "LAB",
                            "native PixelCopy PASS path=${output.absolutePath} " +
                                "source=${sourceBitmap?.width}x${sourceBitmap?.height} " +
                                "surface=${width}x$height attempts=$captureAttempts",
                        )
                        finish()
                    }.onFailure { error ->
                        DiagLog.log("LAB", "native PixelCopy write failed: ${error.message}")
                        finish()
                    }
                } else if (captureAttempts < MAX_CAPTURE_ATTEMPTS) {
                    mainHandler.postDelayed({ captureSurface(holder, width, height) }, 150L)
                } else {
                    DiagLog.log("LAB", "native PixelCopy failed result=$result attempts=$captureAttempts")
                    finish()
                }
                bitmap.recycle()
            },
            mainHandler,
        )
    }

    private fun labFile(name: String): File {
        val safeName = name
            .replace(Regex("[^A-Za-z0-9_.-]"), "_")
            .ifBlank { "capture.png" }
        return File(File(filesDir, "lab"), safeName)
    }

    companion object {
        const val EXTRA_SOURCE_PATH = "sidescreen.lab.source_path"
        const val EXTRA_OUTPUT_NAME = "sidescreen.lab.output_name"
        private const val MAX_CAPTURE_ATTEMPTS = 5
    }
}
