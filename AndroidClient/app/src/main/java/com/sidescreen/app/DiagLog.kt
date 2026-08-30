package com.sidescreen.app

import android.content.Context
import android.util.Log
import java.io.File
import java.util.HashMap
import java.util.concurrent.Executors

/**
 * Shared diagnostic file logger for debugging on devices that suppress logcat.
 * Writes to app-private files directory. Log file is capped at 1MB to prevent unbounded growth.
 */
object DiagLog {
    private const val TAG = "DiagLog"
    private const val LOG_FILE = "diag.log"
    private const val MAX_LOG_SIZE = 1_048_576L // 1MB

    @Volatile
    private var logFile: File? = null

    private val sampledLogLock = Any()
    private val lastSampledLogAtNs = HashMap<String, Long>()

    private val logExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "DiagLogWriter").apply {
                isDaemon = true
            }
        }

    /** Initialize with app context. Call once from Application.onCreate() or MainActivity. */
    fun init(context: Context) {
        logFile = File(context.filesDir, LOG_FILE)
    }

    fun log(
        tag: String,
        msg: String,
    ) {
        Log.d(tag, msg)
        enqueueFileWrite(tag, msg)
    }

    /**
     * Keep every sample in logcat, but persist at most one sample per key in
     * the requested interval. High-frequency diagnostics should not turn a
     * latency probe into a stream of app-private file opens and writes.
     */
    fun logSampled(
        tag: String,
        key: String,
        msg: String,
        intervalMs: Long,
    ) {
        Log.d(tag, msg)
        if (intervalMs <= 0L) {
            enqueueFileWrite(tag, msg)
            return
        }

        val now = System.nanoTime()
        val intervalNs = intervalMs * 1_000_000L
        val shouldPersist = synchronized(sampledLogLock) {
            val previous = lastSampledLogAtNs[key]
            if (previous != null && now - previous < intervalNs) {
                false
            } else {
                lastSampledLogAtNs[key] = now
                true
            }
        }
        if (shouldPersist) {
            enqueueFileWrite(tag, msg)
        }
    }

    private fun enqueueFileWrite(
        tag: String,
        msg: String,
    ) {
        val f = logFile ?: return
        logExecutor.execute {
            try {
                // Rotate if too large
                if (f.exists() && f.length() > MAX_LOG_SIZE) {
                    val backup = File(f.parent, "diag.log.old")
                    backup.delete()
                    f.renameTo(backup)
                }
                f.appendText("[${System.currentTimeMillis()}] $tag: $msg\n")
            } catch (_: Exception) {
            }
        }
    }
}
