package com.sidescreen.app

import android.content.Context
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter

/**
 * Opt-in raw render trace writer for the motion lab.
 *
 * Production sessions do not write one file row per frame. The recorder is
 * enabled only by the exported lab command and writes inside the app-private
 * directory so a run can be pulled with `run-as` without adding storage
 * permissions or exposing a socket/file endpoint.
 */
object FrameTraceRecorder {
    private val lock = Any()
    private var writer: BufferedWriter? = null
    private var rowsSinceFlush = 0
    private var currentFile: File? = null

    fun start(context: Context, requestedName: String): File {
        synchronized(lock) {
            stopLocked()
            val directory = File(context.filesDir, "lab")
            directory.mkdirs()
            val safeName = requestedName
                .replace(Regex("[^A-Za-z0-9_.-]"), "_")
                .ifBlank { "frame-trace" }
                .removeSuffix(".csv") + ".csv"
            val file = File(directory, safeName)
            val nextWriter = BufferedWriter(FileWriter(file, false))
            nextWriter.write(
                "frame_id,host_capture_ns,capture_ns,received_ns," +
                    "input_queued_ns,output_available_ns,output_release_requested_ns," +
                    "surface_rendered_ns\n",
            )
            nextWriter.flush()
            writer = nextWriter
            currentFile = file
            rowsSinceFlush = 0
            return file
        }
    }

    fun record(trace: FrameTrace) {
        synchronized(lock) {
            val activeWriter = writer ?: return
            activeWriter.write(
                "${trace.frameId},${trace.hostCaptureNs},${trace.captureNs}," +
                    "${trace.receivedNs},${trace.inputQueuedNs},${trace.outputAvailableNs}," +
                    "${trace.outputReleaseRequestedNs},${trace.surfaceRenderedNs}\n",
            )
            rowsSinceFlush++
            if (rowsSinceFlush >= 30) {
                activeWriter.flush()
                rowsSinceFlush = 0
            }
        }
    }

    fun stop() {
        synchronized(lock) { stopLocked() }
    }

    fun currentFile(): File? = synchronized(lock) { currentFile }

    private fun stopLocked() {
        runCatching { writer?.flush() }
        runCatching { writer?.close() }
        writer = null
        currentFile = null
        rowsSinceFlush = 0
    }
}
