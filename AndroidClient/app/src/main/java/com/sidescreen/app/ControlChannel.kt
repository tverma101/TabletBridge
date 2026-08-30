package com.sidescreen.app

import android.net.Network
import android.os.Process
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Out-of-band control channel: ping/pong RTT measurement + keyframe requests
 * on a path that never contends with the video stream.
 *
 * TCP-only. The channel's own connection carries nothing but pings/pongs, so
 * a pong is never queued behind video frames (the in-band path's ~40-1000ms
 * spikes under load). The tunnel's TCP carriage stall was fixed by replacing
 * toybox nc (no TCP_NODELAY) with a NODELAY relay on the tablet side, so a
 * dedicated TCP control connection now rides at true tunnel latency.
 *
 * Wire format (little-endian):
 *   client -> server: PING     = [type 4][clientTs 8]
 *   client -> server: KEYFRAME = [type 7][flags 1]
 *   client -> server: SUPPORT_BRIGHTNESS = [type 3]   (payload-free capability)
 *   server -> client: PONG     = [type 5][clientTs 8 (echo)][serverReceiveTs 8][serverSendTs 8]
 *   server -> client: BRIGHT   = [type 11][value 1]   (0..255, real backlight)
 */
class ControlChannel(
    private val host: String,
    private val port: Int,
) {
    var onLatencyMeasured: ((Double) -> Unit)? = null
    var onClockSyncMeasured: ((ClockSyncEstimate) -> Unit)? = null

    /** Server→client brightness command: 0..255, apply to the REAL panel. */
    var onBrightnessCommand: ((Int) -> Unit)? = null

    /** True when the optional control socket is usable; false is degraded,
     * not a video-session failure. */
    var onAvailabilityChanged: ((Boolean) -> Unit)? = null

    // TCP path
    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    @Volatile
    private var tcpActive = false

    @Volatile
    private var running = false

    @Volatile
    private var lastPongAtNs = 0L

    @Volatile
    private var lastPingSentAtNs = 0L

    @Volatile
    private var clockSyncReady = false
    private var clockSyncEstimator = ClockOffsetEstimator()

    private val sendLock = Any()
    private val connectLock = Any()
    @Volatile private var boundNetwork: Network? = null

    val isConnected: Boolean
        get() = tcpActive

    /** Bind the optional control socket to the same Wi-Fi route as video. */
    fun bindTo(network: Network?) {
        boundNetwork = network
    }

    /**
     * Best-effort: never throws — failures fall back to in-band ping/pong.
     *
     * This is intentionally a single attempt for each explicit video
     * connection. The control path is optional; retrying it in the background
     * can create a reconnect storm when the host is stopping or already has a
     * client, and it does not improve the video connection.
     */
    fun connect() {
        synchronized(connectLock) {
            if (running) return
            running = true
        }
        Thread({ tryTcp() }, "ControlConnect")
            .apply {
                isDaemon = true
                priority = Thread.MAX_PRIORITY
            }.start()
    }

    private fun tryTcp() {
        synchronized(connectLock) {
            if (!running || socket != null) return
            val s = Socket()
            try {
                // Bounded connect: never let the control path hang the caller.
                boundNetwork?.let { network ->
                    try {
                        network.bindSocket(s)
                        DiagLog.log("CC", "Control socket bound to the wireless video route")
                    } catch (e: Exception) {
                        // The control path is optional. If the route has gone
                        // away, let the normal routing table try once rather
                        // than turning a video session into a reconnect.
                        DiagLog.log("CC", "Wireless control bind failed: ${e.message}; using default route")
                    }
                }
                s.connect(InetSocketAddress(host, port), 2000)
                s.tcpNoDelay = true
                socket = s
                output = DataOutputStream(s.getOutputStream())
                lastPongAtNs = System.nanoTime()
                lastPingSentAtNs = 0L
                clockSyncReady = false
                clockSyncEstimator = ClockOffsetEstimator()
                // Active from connect, NOT from the first pong: StreamClient
                // only pings via control when isConnected, so waiting for a
                // pong before declaring active deadlocks the first ping.
                tcpActive = true
                DiagLog.log("CC", "Control channel ACTIVE mode=tcp")
                onAvailabilityChanged?.invoke(true)
                declareBrightnessSupport()
                declareClockSyncSupport()
                Thread({ tcpReadLoop(s) }, "ControlTcpThread")
                    .apply { isDaemon = true }
                    .start()
            } catch (e: Exception) {
                DiagLog.log("CC", "Control channel TCP connect failed: ${e.message}")
                socket = null
                output = null
                tcpActive = false
                onAvailabilityChanged?.invoke(false)
                try {
                    s.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun tcpReadLoop(s: Socket) {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
        } catch (_: Exception) {
        }
        try {
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 4096))
            while (running && socket === s) {
                val type = input.readByte().toInt()
                val arrival = System.nanoTime()
                    when (type) {
                    5 -> { // Pong: [clientTs 8][serverSendTs 8]
                        // New hosts return t0, t1=Mac receive, t2=Mac send.
                        // Old hosts return only t0 and t2; capability is sent
                        // before the first periodic ping.
                        val buf = ByteArray(if (clockSyncReady) 24 else 16)
                        input.readFully(buf)
                        val bb = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
                        val clientTs = bb.long
                        val rtt: Double
                        if (clockSyncReady) {
                            val serverReceiveTs = bb.long
                            val serverSendTs = bb.long
                            val receivedAt = System.nanoTime()
                            val estimate = clockSyncEstimator.addSample(
                                androidSendNs = clientTs,
                                macReceiveNs = serverReceiveTs,
                                macSendNs = serverSendTs,
                                androidReceiveNs = receivedAt,
                            )
                            rtt = estimate.rttNs / 1_000_000.0
                            if (estimate.accepted) {
                                onClockSyncMeasured?.invoke(estimate)
                            }
                        } else {
                            bb.long // legacy server send timestamp
                            rtt = (arrival - clientTs) / 1_000_000.0
                        }
                        val processedAt = System.nanoTime()
                        lastPongAtNs = arrival
                        val appDelay = (processedAt - arrival) / 1_000_000.0
                        DiagLog.logSampled(
                            "CC",
                            "control-pong",
                            String.format(
                                "PONG rtt=%.2fms appDelay=%.3fms transit=%.2fms mode=tcp",
                                rtt,
                                appDelay,
                                rtt - appDelay,
                            ),
                            DIAGNOSTIC_SAMPLE_INTERVAL_MS,
                        )
                        if (!tcpActive) {
                            tcpActive = true
                            DiagLog.log("CC", "Control channel ACTIVE mode=tcp")
                        }
                        onLatencyMeasured?.invoke(rtt)
                    }

                    11 -> { // Bright: [value 1] 0..255 — REAL panel backlight
                        val value = input.readByte().toInt() and 0xFF
                        DiagLog.log("CC", "BRIGHT command value=$value")
                        onBrightnessCommand?.invoke(value)
                    }

                    12 -> { // Clock-sync capability acknowledgement
                        clockSyncReady = true
                        DiagLog.log("CC", "Clock synchronization acknowledged by host")
                    }

                    else -> {
                        DiagLog.log("CC", "Unknown control type $type — disconnecting")
                        return
                    }
                }
            }
        } catch (e: Exception) {
            if (running) {
                DiagLog.log("CC", "Control read error: ${e.message}")
            }
        } finally {
            markTcpInactive(s)
        }
    }

    /** Tell the server we understand BRIGHT (type 11). Old servers log-only. */
    private fun declareBrightnessSupport() {
        val out = output ?: return
        synchronized(sendLock) {
            try {
                out.write(byteArrayOf(3))
                out.flush()
                DiagLog.log("CC", "Declared brightness support")
            } catch (e: Exception) {
                DiagLog.log("CC", "Brightness declaration failed: ${e.message}")
            }
        }
    }

    /** Tell new hosts that extended pong timestamps are safe to send. */
    private fun declareClockSyncSupport() {
        val out = output ?: return
        synchronized(sendLock) {
            try {
                out.writeByte(13)
                out.flush()
                DiagLog.log("CC", "Advertised clock synchronization support")
            } catch (e: Exception) {
                DiagLog.log("CC", "Clock synchronization declaration failed: ${e.message}")
            }
        }
    }

    /** Returns false when the caller should use its in-band fallback. */
    fun sendPing(): Boolean {
        val activeSocket = socket ?: return false
        val out = output ?: return false
        val now = System.nanoTime()
        if (lastPingSentAtNs > lastPongAtNs && now - lastPongAtNs > PONG_TIMEOUT_NS) {
            DiagLog.log("CC", "Control pong timeout — using in-band fallback")
            markTcpInactive(activeSocket)
            return false
        }
        val ts = System.nanoTime()
        synchronized(sendLock) {
            return try {
                val buffer = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
                buffer.put(4.toByte())
                buffer.putLong(ts)
                out.write(buffer.array())
                out.flush()
                lastPingSentAtNs = ts
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control ping write failed: ${e.message}")
                markTcpInactive(activeSocket)
                false
            }
        }
    }

    /** Returns false when the caller should use its in-band fallback. */
    fun requestKeyframe(force: Boolean): Boolean {
        val activeSocket = socket ?: return false
        val out = output ?: return false
        synchronized(sendLock) {
            return try {
                out.write(byteArrayOf(7.toByte(), if (force) 1 else 0))
                out.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control keyframe write failed: ${e.message}")
                markTcpInactive(activeSocket)
                false
            }
        }
    }

    /** Send pointer input on the low-latency path, preserving event order. */
    fun sendTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int,
        x2: Float,
        y2: Float,
    ): Boolean {
        val activeSocket = socket ?: return false
        val out = output ?: return false
        val count = pointerCount.coerceIn(1, 2)
        val buffer = ByteBuffer.allocate(6 + count * 8).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(2.toByte())
        buffer.put(count.toByte())
        buffer.putFloat(x)
        buffer.putFloat(y)
        if (count == 2) {
            buffer.putFloat(x2)
            buffer.putFloat(y2)
        }
        buffer.putInt(action)

        synchronized(sendLock) {
            return try {
                out.write(buffer.array())
                out.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control touch write failed: ${e.message}")
                markTcpInactive(activeSocket)
                false
            }
        }
    }

    private fun markTcpInactive(expectedSocket: Socket) {
        synchronized(connectLock) {
            if (socket !== expectedSocket) return
            tcpActive = false
            output = null
            socket = null
            lastPongAtNs = 0L
            lastPingSentAtNs = 0L
            clockSyncReady = false
            try {
                expectedSocket.close()
            } catch (_: Exception) {
            }
            if (running) {
                DiagLog.log("CC", "Control channel unavailable — using in-band fallback")
            }
            onAvailabilityChanged?.invoke(false)
        }
    }

    fun disconnect() {
        synchronized(connectLock) {
            running = false
            val wasActive = tcpActive
            tcpActive = false
            output = null
            lastPongAtNs = 0L
            lastPingSentAtNs = 0L
            clockSyncReady = false
            val activeSocket = socket
            socket = null
            try {
                activeSocket?.close()
            } catch (_: Exception) {
            }
            if (wasActive) onAvailabilityChanged?.invoke(false)
        }
    }

    private companion object {
        const val PONG_TIMEOUT_NS = 3_000_000_000L
        const val DIAGNOSTIC_SAMPLE_INTERVAL_MS = 10_000L
    }
}
