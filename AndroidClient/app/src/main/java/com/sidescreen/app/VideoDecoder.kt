package com.sidescreen.app

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Display
import android.view.Surface
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

private fun diagLog(msg: String) = DiagLog.log("VD", msg)

class VideoDecoder(
    private val surface: Surface,
    private val display: Display? = null,
    initialWidth: Int = 1920,
    initialHeight: Int = 1200,
    // Exposed so MainActivity can detect a codec-negotiation/decoder mismatch
    // and recreate the decoder (see MainActivity.onStreamCodecSelected).
    val mime: String = MediaFormat.MIMETYPE_VIDEO_HEVC,
    /** Wireless sends a bounded 60 FPS stream even on a 120 Hz panel. */
    private val targetFrameRate: Int? = null,
    /** CfL path: configure with NO output surface and hand decoded Images
     *  to [onDecodedImage] via getOutputImage() — the only plane-accessible
     *  output on this SoC (ImageReader surfaces deliver opaque UBWC buffers
     *  whose plane access is a fatal JNI abort). */
    private val bufferOutput: Boolean = false,
) {
    private var decoder: MediaCodec? = null
    private var decoderThread: HandlerThread? = null
    private var decoderHandler: Handler? = null

    private var frameCount = 0L
    private var droppedFrames = 0L
    private var staleOutputDrops = 0L
    private var lastStatsTime = System.currentTimeMillis()
    private var inputFrameCount = 0L
    private var outputFrameCount = 0L

    // A MediaCodec input buffer can be returned just after the socket thread
    // checks the queue. Treating that normal hand-off race as frame loss is
    // especially destructive for HEVC: one discarded P-frame invalidates the
    // reference chain and the forced IDR used to recover creates another large
    // decode burst. Wait for at most three 120-Hz frame periods instead. The wait
    // also provides a short, explicit backpressure boundary to the socket when
    // a producer burst briefly outruns the hardware decoder. The sender-side
    // Mac credit gate should make this path exceptional rather than a normal
    // frame cadence.
    private var inputBufferWaitCount = 0L
    private var inputBufferWaitSumNs = 0L
    private var inputBufferWaitMaxNs = 0L
    private var inputBufferWaitTimeouts = 0L

    // Decoder pipeline latency (input enqueue -> output buffer available),
    // accumulated over ~60 frames then logged. High values indicate the codec
    // is queuing frames internally (compose/present can't keep up downstream),
    // which surfaces to the user as input lag on the captured display.
    private var latencySumNs: Long = 0
    private var latencySamples: Int = 0
    private var latencyMaxNs: Long = 0
    private val pendingFrameTraces = ConcurrentHashMap<Long, FrameTrace>()
    private val pendingSurfaceTraces = ConcurrentHashMap<Long, FrameTrace>()
    private val traceStats = FrameTraceStats()
    private var traceOutputCount = 0L
    private var selectedDecoder: DecoderCapability? = null
    private var frameRenderedListenerInstalled = false

    private val frameTimes = ArrayDeque<Long>(120)

    private val displayRefreshRate =
        (targetFrameRate?.toFloat() ?: display?.refreshRate ?: 60f).coerceIn(30f, 240f)

    private var currentWidth = initialWidth
    private var currentHeight = initialHeight

    @Volatile private var isRunning = false

    @Volatile private var needsKeyframe = true

    private var lastKeyframeRequestNs = 0L

    var onFrameRendered: ((Long) -> Unit)? = null
    /** First output buffer became available. This is decoder evidence, not
     *  Surface visibility. */
    var onFirstFrameDecoded: (() -> Unit)? = null
    var onFrameStats: ((fps: Double, variance: Double) -> Unit)? = null
    var onFrameDecoded: ((ByteArray) -> Unit)? = null
    var onKeyframeRequired: ((force: Boolean, reason: String) -> Unit)? = null

    // ByteBuffer-mode (CfL) hand-off. The sink consumes the Image on another
    // thread and invokes the returned callback (which releases the output
    // buffer) when done.
    var onDecodedImage: ((android.media.Image, () -> Unit) -> Unit)? = null
    var onImageOutputUnavailable: (() -> Unit)? = null
    private var imageUnavailableSignalled = false

    /** Decoded stream color range: 1 = full, 2 = limited (video swing). */
    var onColorRange: ((Int) -> Unit)? = null
    /** Decoder pipeline latency (avg/max ms over the last ~60 frames). */
    var onDecodeLatency: ((avgMs: Double, maxMs: Double) -> Unit)? = null
    /** Actual decoded stream size + crop (from the codec output format — the TRUE frame
     *  geometry, which can differ from the configured size when the sender's display
     *  message carries logical dims while the SPS carries physical dims). */
    var onDecodedFormat: ((width: Int, height: Int, cropL: Int, cropR: Int, cropT: Int, cropB: Int) -> Unit)? = null
    /** Called after a decoded frame is released for rendering when trace data exists. */
    var onFrameTrace: ((FrameTrace) -> Unit)? = null

    /** Fired once when the decoder has accepted many frames but never output any —
     *  the black-screen-with-live-stats signature (stream above the device's
     *  decode limit, or an unusable decoder). Counts only frames actually queued
     *  to MediaCodec, so pre-keyframe drops on a slow start can't trigger it. */
    var onDecoderStalled: (() -> Unit)? = null
    private var stallReported = false
    private var queuedInputCount = 0L

    // Available input buffer indices — fed by onInputBufferAvailable callback
    private val availableInputBuffers = LinkedBlockingQueue<Int>()

    init {
        setupDecoder()
    }

    fun updateResolution(
        width: Int,
        height: Int,
    ) {
        if (width != currentWidth || height != currentHeight) {
            currentWidth = width
            currentHeight = height
            release()
            setupDecoder()
            requestKeyframe("resolution changed", force = true)
        }
    }

    private fun setupDecoder() {
        frameRenderedListenerInstalled = false
        selectedDecoder = null
        decoderThread = HandlerThread("DecoderThread", Process.THREAD_PRIORITY_DISPLAY).also { it.start() }
        decoderHandler = Handler(decoderThread!!.looper)

        // Find a decoder that supports our resolution (prefer HW, fallback to SW)
        val decoderName = findBestDecoder(currentWidth, currentHeight)
        diagLog("setupDecoder: ${currentWidth}x$currentHeight, decoder=$decoderName")

        val codec =
            if (decoderName != null) {
                MediaCodec.createByCodecName(decoderName)
            } else {
                MediaCodec.createDecoderByType(mime)
            }

        val callback =
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                ) {
                    availableInputBuffers.offer(index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    handleOutputBuffer(codec, index, info)
                }

                override fun onError(
                    codec: MediaCodec,
                    e: MediaCodec.CodecException,
                ) {
                    diagLog("Codec error: ${e.diagnosticInfo}")
                    Log.e(TAG, "Codec error: ${e.diagnosticInfo}", e)
                    needsKeyframe = true
                    requestKeyframe("codec error", force = true)
                }

                override fun onOutputFormatChanged(
                    codec: MediaCodec,
                    format: MediaFormat,
                ) {
                    diagLog("Output format changed: $format")
                    runCatching {
                        val w = format.getInteger(MediaFormat.KEY_WIDTH)
                        val h = format.getInteger(MediaFormat.KEY_HEIGHT)
                        val cl = runCatching { format.getInteger("crop-left") }.getOrDefault(0)
                        val cr = runCatching { format.getInteger("crop-right") }.getOrDefault(0)
                        val ct = runCatching { format.getInteger("crop-top") }.getOrDefault(0)
                        val cb = runCatching { format.getInteger("crop-bottom") }.getOrDefault(0)
                        onDecodedFormat?.invoke(w, h, cl, cr, ct, cb)
                    }
                    // color-range: 1 = full, 2 = limited/video (observed on
                    // this decoder: 8-bit SCK capture → 1, 10-bit VideoRange
                    // capture → 2). The CfL renderer needs it to pick the
                    // right YUV→RGB matrix.
                    val range = runCatching { format.getInteger("color-range") }.getOrDefault(1)
                    diagLog("color-range=$range (${if (range == 2) "limited" else "full"})")
                    onColorRange?.invoke(range)
                }
            }
        codec.setCallback(callback, decoderHandler)

        if (!bufferOutput && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                codec.setOnFrameRenderedListener({ _, presentationTimeUs, nanoTime ->
                    val trace = pendingSurfaceTraces.remove(presentationTimeUs)
                    trace?.let {
                        recordFrameTrace(it.copy(surfaceRenderedNs = nanoTime))
                    }
                    trackFrameTiming(nanoTime)
                }, decoderHandler)
                frameRenderedListenerInstalled = true
                diagLog("OnFrameRenderedListener installed for $mime")
            } catch (e: Exception) {
                frameRenderedListenerInstalled = false
                diagLog("OnFrameRenderedListener unavailable: ${e.message}")
            }
        }

        val format =
            MediaFormat.createVideoFormat(
                mime,
                currentWidth,
                currentHeight,
            )

        val targetSurface: Surface? = if (bufferOutput) null else surface

        val lowLatencyAdvertised = selectedDecoder?.supportsLowLatency == true
        if (lowLatencyAdvertised && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, displayRefreshRate.toInt())

        try {
            codec.configure(format, targetSurface, null, 0)
            diagLog(
                "Configured decoder path=${if (lowLatencyAdvertised) "low-latency-capability" else "standard"} " +
                    "codec=${selectedDecoder?.name ?: "default"}" +
                    "${if (bufferOutput) " (buffer output)" else ""}",
            )
        } catch (e: Exception) {
            // Retry only with decoder-safe keys. KEY_MAX_B_FRAMES is an
            // encoder setting and must never be passed to a decoder.
            diagLog("Capability-selected decoder config failed: ${e.message}; retrying minimal decoder format")
            try {
                codec.reset()
                codec.setCallback(callback, decoderHandler)
                if (!bufferOutput && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    codec.setOnFrameRenderedListener({ _, presentationTimeUs, nanoTime ->
                        val trace = pendingSurfaceTraces.remove(presentationTimeUs)
                        trace?.let { recordFrameTrace(it.copy(surfaceRenderedNs = nanoTime)) }
                        trackFrameTiming(nanoTime)
                    }, decoderHandler)
                    frameRenderedListenerInstalled = true
                }
                val minimalFormat = MediaFormat.createVideoFormat(mime, currentWidth, currentHeight)
                codec.configure(minimalFormat, targetSurface, null, 0)
                diagLog("Configured minimal decoder format after capability-path failure")
            } catch (minimalError: Exception) {
                diagLog("All decoder configure attempts failed: ${minimalError.message}")
                Log.e(TAG, "All configure attempts failed", minimalError)
                codec.release()
                decoderThread?.quitSafely()
                decoderThread = null
                decoderHandler = null
                throw minimalError
            }
        }

        codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        needsKeyframe = true
        isRunning = true
        codec.start()
        decoder = codec
        runCatching { diagLog("Codec metrics at start: ${codec.metrics}") }
        diagLog(
            "Decoder started: ${currentWidth}x$currentHeight @ ${displayRefreshRate}Hz, " +
                "surface=$surface, valid=${surface.isValid}, " +
                "renderCallback=$frameRenderedListenerInstalled",
        )
    }

    /**
     * Find the best decoder for [mime] at the given resolution.
     * Prefers hardware decoders, falls back to software if HW can't handle the resolution.
     * Returns codec name to use with MediaCodec.createByCodecName(), or null for default.
     */
    private fun findBestDecoder(
        width: Int,
        height: Int,
    ): String? {
        try {
            val targetRate = displayRefreshRate.toDouble().coerceAtLeast(30.0)
            val candidates = CodecCapabilities.decoderCandidates(mime, width, height, targetRate)
            candidates.forEach { candidate ->
                diagLog(
                    "$mime decoder '${candidate.name}': hw=${candidate.isHardware} " +
                        "vendor=${candidate.isVendor} size=${candidate.supportsSize} " +
                        "rate=${candidate.supportsRate} lowLatency=${candidate.supportsLowLatency} " +
                        "profiles=${candidate.profileLevels}",
                )
            }

            val chosen = candidates
                .filter { it.supportsSize }
                .sortedWith(
                    compareByDescending<DecoderCapability> { it.isHardware }
                        .thenByDescending { it.supportsLowLatency }
                        .thenByDescending { it.supportsRate },
                )
                .firstOrNull()
            selectedDecoder = chosen
            if (chosen != null) {
                diagLog(
                    "Selected decoder: ${chosen.name} hw=${chosen.isHardware} " +
                        "vendor=${chosen.isVendor} rate=${chosen.supportsRate} " +
                        "lowLatency=${chosen.supportsLowLatency} profiles=${chosen.profileLevels}",
                )
            } else {
                diagLog("No decoder supports ${width}x$height — will use platform default")
            }
            return chosen?.name
        } catch (e: Exception) {
            diagLog("Decoder search failed: ${e.message}")
        }
        return null
    }

    @Suppress("UNUSED_PARAMETER")
    fun decode(
        frameData: ByteArray,
        frameSize: Int = frameData.size,
        frameTimestamp: Long = System.nanoTime(),
        isKeyframe: Boolean = false,
        trace: FrameTrace? = null,
    ) {
        if (!isRunning) {
            diagLog("decode called but isRunning=false")
            onFrameDecoded?.invoke(frameData)
            return
        }

        inputFrameCount++
        if (inputFrameCount == 1L) {
            val header =
                frameData
                    .take(minOf(16, frameSize))
                    .joinToString(" ") { String.format("%02x", it) }
            diagLog(
                "First frame: size=$frameSize, header=[$header], " +
                    "keyframe=$isKeyframe, surface=$surface, valid=${surface.isValid}",
            )
        }
        if (inputFrameCount % 60L == 0L) {
            diagLog(
                "Decode stats: input=$inputFrameCount, output=$outputFrameCount, " +
                    "dropped=$droppedFrames, availBufs=${availableInputBuffers.size}",
            )
        }
        val codec =
            decoder ?: run {
                diagLog("decoder is null in decode()")
                onFrameDecoded?.invoke(frameData)
                return
            }

        if (needsKeyframe && !isKeyframe) {
            dropFrame(
                frameData,
                isKeyframe,
                "waiting for keyframe",
                waitForKeyframe = true,
            )
            return
        }

        // Fast path is still non-blocking. Only wait when the callback hand-off
        // queue is momentarily empty, and never for longer than one 60-Hz frame.
        var index = availableInputBuffers.poll()
        if (index == null) {
            val waitStartedNs = System.nanoTime()
            index =
                try {
                    availableInputBuffers.poll(INPUT_BUFFER_WAIT_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    null
                }
            val waitedNs = System.nanoTime() - waitStartedNs
            inputBufferWaitCount++
            inputBufferWaitSumNs += waitedNs
            if (waitedNs > inputBufferWaitMaxNs) inputBufferWaitMaxNs = waitedNs
        }
        if (index == null) {
            // This is genuine decoder pressure, not the callback race above.
            // Do not feed later P-frames against a missing reference: that is
            // the visible cursor tear/glitch. Pause until the requested IDR.
            droppedFrames++
            inputBufferWaitTimeouts++
            needsKeyframe = true
            if (droppedFrames <= 3L || droppedFrames % 60L == 0L) {
                diagLog(
                    "Dropping frame (no input buffer after ${INPUT_BUFFER_WAIT_MS}ms, " +
                        "dropped=$droppedFrames, timeouts=$inputBufferWaitTimeouts)",
                )
            }
            requestKeyframe("no input buffer", force = true)
            onFrameDecoded?.invoke(frameData)
            return
        }

        queueFrame(codec, index, frameData, frameSize, isKeyframe, trace)
    }

    private fun queueFrame(
        codec: MediaCodec,
        index: Int,
        frameData: ByteArray,
        frameSize: Int,
        isKeyframe: Boolean,
        trace: FrameTrace?,
    ) {
        var queuedPresentationTimeUs: Long? = null
        try {
            val inputBuffer =
                codec.getInputBuffer(index)
                    ?: throw IllegalStateException("Input buffer $index is null")
            inputBuffer.clear()
            inputBuffer.put(frameData, 0, frameSize)
            // MediaCodec PTS stays in the Android clock domain so decoder
            // latency remains input-queue -> output. Cross-device capture
            // timing travels in the side-channel trace map instead of being
            // confused with codec latency.
            val queuedAtNs = System.nanoTime()
            val presentationTimeUs = queuedAtNs / 1000L
            queuedPresentationTimeUs = presentationTimeUs
            trace?.let { pendingFrameTraces[presentationTimeUs] = it.copy(inputQueuedNs = queuedAtNs) }
            codec.queueInputBuffer(index, 0, frameSize, presentationTimeUs, 0)
            queuedInputCount++
            if (queuedInputCount == STALL_DETECT_INPUT_FRAMES && outputFrameCount == 0L && !stallReported) {
                stallReported = true
                diagLog("Decoder stalled: $queuedInputCount frames queued, none out")
                onDecoderStalled?.invoke()
            }
            if (isKeyframe) {
                needsKeyframe = false
            }
        } catch (e: Exception) {
            needsKeyframe = true
            queuedPresentationTimeUs?.let { pendingFrameTraces.remove(it) }
            requestKeyframe("queue input failed")
            Log.e(TAG, "decode direct feed error", e)
        } finally {
            onFrameDecoded?.invoke(frameData)
        }
    }

    private fun dropFrame(
        frameData: ByteArray,
        isKeyframe: Boolean,
        reason: String,
        waitForKeyframe: Boolean,
        requestRefresh: Boolean = waitForKeyframe,
    ) {
        droppedFrames++
        if (droppedFrames <= 3L || droppedFrames % 60L == 0L) {
            diagLog("Dropping frame ($reason, keyframe=$isKeyframe, dropped=$droppedFrames)")
        }
        if (waitForKeyframe) {
            needsKeyframe = true
        }
        if (requestRefresh) {
            requestKeyframe(reason)
        }
        onFrameDecoded?.invoke(frameData)
    }

    private fun requestKeyframe(
        reason: String,
        force: Boolean = false,
    ) {
        val now = System.nanoTime()
        val interval =
            if (force) FORCE_KEYFRAME_REQUEST_INTERVAL_NS else KEYFRAME_REQUEST_INTERVAL_NS
        if (now - lastKeyframeRequestNs < interval) {
            return
        }
        lastKeyframeRequestNs = now
        diagLog("Requesting keyframe: reason=$reason, force=$force")
        onKeyframeRequired?.invoke(force, reason)
    }

    private fun handleOutputBuffer(
        codec: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
    ) {
        try {
            outputFrameCount++
            if (outputFrameCount == 1L) {
                onFirstFrameDecoded?.invoke()
            }
            if (outputFrameCount == 1L) {
                diagLog("First output frame! size=${info.size}, flags=${info.flags}")
            }

            val outputAvailableNs = System.nanoTime()
            val trace = pendingFrameTraces.remove(info.presentationTimeUs)

            // ByteBuffer mode (CfL): hand the plane-accessible Image to the
            // renderer; it releases the buffer from its render thread via
            // the consumed callback.
            if (bufferOutput) {
                val sink = onDecodedImage
                val img =
                    try {
                        if (info.size > 0) codec.getOutputImage(index) else null
                    } catch (e: Exception) {
                        diagLog("getOutputImage failed: ${e.message}")
                        null
                    }
                if (sink != null && img != null) {
                    sink(img) {
                            val releaseRequestedNs = System.nanoTime()
                            try {
                                codec.releaseOutputBuffer(index, false)
                        } catch (_: Exception) {
                        }
                        trace?.let { completedTrace ->
                            val renderedTrace = completedTrace.copy(
                                outputAvailableNs = outputAvailableNs,
                                outputReleaseRequestedNs = releaseRequestedNs,
                            )
                            recordFrameTrace(renderedTrace)
                        }
                        updateStats()
                    }
                    return
                }
                if (img == null && !imageUnavailableSignalled) {
                    imageUnavailableSignalled = true
                    diagLog("getOutputImage unavailable — buffer-output CfL cannot run")
                    onImageOutputUnavailable?.invoke()
                }
                codec.releaseOutputBuffer(index, false)
                updateStats()
                return
            }

            // Decoder latency: time from queueInputBuffer (where we encoded
            // System.nanoTime()/1000 as PTS) to now. Captures how long the
            // frame spent inside the codec's input/reorder/output queues.
            val nowNs = outputAvailableNs
            val latencyNs = nowNs - info.presentationTimeUs * 1000L
            val hasValidLatency = latencyNs in 0..MAX_REASONABLE_LATENCY_NS
            if (hasValidLatency) {
                latencySumNs += latencyNs
                latencySamples++
                if (latencyNs > latencyMaxNs) latencyMaxNs = latencyNs
            }

            if (outputFrameCount % 60L == 0L) {
                val avgMs = if (latencySamples > 0) latencySumNs / latencySamples / 1_000_000.0 else 0.0
                val maxMs = latencyMaxNs / 1_000_000.0
                val inputWaitAvgMs =
                    if (inputBufferWaitCount > 0) {
                        inputBufferWaitSumNs / inputBufferWaitCount / 1_000_000.0
                    } else {
                        0.0
                    }
                val inputWaitMaxMs = inputBufferWaitMaxNs / 1_000_000.0
                val inBufs = availableInputBuffers.size
                diagLog(
                    "Output #$outputFrameCount: decoder latency avg=${"%.1f".format(avgMs)}ms " +
                        "max=${"%.1f".format(maxMs)}ms over $latencySamples samples, " +
                        "input bufs avail=$inBufs, dropped=$droppedFrames, " +
                        "inputWait avg=${"%.2f".format(inputWaitAvgMs)}ms " +
                        "max=${"%.2f".format(inputWaitMaxMs)}ms timeouts=$inputBufferWaitTimeouts",
                )
                onDecodeLatency?.invoke(avgMs, maxMs)
                latencySumNs = 0
                latencySamples = 0
                latencyMaxNs = 0
                inputBufferWaitCount = 0
                inputBufferWaitSumNs = 0
                inputBufferWaitMaxNs = 0
                inputBufferWaitTimeouts = 0
            }

            val shouldRender =
                outputFrameCount == 1L ||
                    !hasValidLatency ||
                    latencyNs <= MAX_RENDER_LATENCY_NS

            if (!shouldRender) {
                droppedFrames++
                staleOutputDrops++
                if (staleOutputDrops <= 3L || staleOutputDrops % 60L == 0L) {
                    diagLog(
                        "Dropping stale output frame: latency=${"%.1f".format(latencyNs / 1_000_000.0)}ms, " +
                            "staleDrops=$staleOutputDrops",
                    )
                }
                codec.releaseOutputBuffer(index, false)
                updateStats()
                return
            }

            val releaseRequestedNs = System.nanoTime()
            trace?.let { completedTrace ->
                pendingSurfaceTraces[info.presentationTimeUs] = completedTrace.copy(
                    outputAvailableNs = nowNs,
                    outputReleaseRequestedNs = releaseRequestedNs,
                )
            }
            codec.releaseOutputBuffer(index, true)
            if (!frameRenderedListenerInstalled) {
                // API 23+ normally supplies the callback. If a vendor codec
                // omits it, keep the metric explicitly named as a release
                // request and do not call it surface-visible.
                diagLog("Surface render callback unavailable; output release request recorded only")
            }
            updateStats()
        } catch (e: Exception) {
            Log.e(TAG, "releaseOutputBuffer failed", e)
            try {
                codec.releaseOutputBuffer(index, false)
            } catch (_: Exception) {
            }
        }
    }

    private fun trackFrameTiming(timestamp: Long) {
        frameTimes.addLast(timestamp)
        if (frameTimes.size > 120) frameTimes.removeFirst()

        if (frameTimes.size >= 60 && frameCount % 60L == 0L) {
            val deltas = frameTimes.zipWithNext { a, b -> (b - a) / 1_000_000.0 }
            if (deltas.isNotEmpty()) {
                val avgDelta = deltas.average()
                val variance = deltas.map { (it - avgDelta) * (it - avgDelta) }.average()
                val stdDev = kotlin.math.sqrt(variance)
                onFrameStats?.invoke(1000.0 / avgDelta, stdDev)
            }
        }
        onFrameRendered?.invoke(timestamp)
    }

    private fun recordFrameTrace(trace: FrameTrace) {
        traceStats.add(trace)
        traceOutputCount++
        onFrameTrace?.invoke(trace)
        if (traceOutputCount % 60L == 0L) {
            val receiveMs =
                if (trace.receivedNs > 0L && trace.receivedNs >= trace.captureNs) {
                    (trace.receivedNs - trace.captureNs) / 1_000_000.0
                } else {
                    0.0
                }
            val queueMs =
                if (trace.inputQueuedNs >= trace.receivedNs) {
                    (trace.inputQueuedNs - trace.receivedNs) / 1_000_000.0
                } else {
                    0.0
                }
            val decodeMs =
                if (trace.outputAvailableNs >= trace.inputQueuedNs) {
                    (trace.outputAvailableNs - trace.inputQueuedNs) / 1_000_000.0
                } else {
                    0.0
                }
            val releaseMs =
                if (trace.outputReleaseRequestedNs >= trace.outputAvailableNs) {
                    (trace.outputReleaseRequestedNs - trace.outputAvailableNs) / 1_000_000.0
                } else {
                    0.0
                }
            val surfaceMs =
                if (trace.surfaceRenderedNs >= trace.outputReleaseRequestedNs && trace.surfaceRenderedNs > 0L) {
                    (trace.surfaceRenderedNs - trace.outputReleaseRequestedNs) / 1_000_000.0
                } else {
                    0.0
            }
            val summary = traceStats.summary()
            val pacing = traceStats.pacingSummary()
            if (summary != null) {
                diagLog(
                    "Trace frame=${trace.frameId} stages=" +
                        "capture->receive=${"%.2f".format(receiveMs)}ms " +
                        "receive->queue=${"%.2f".format(queueMs)}ms " +
                        "queue->output=${"%.2f".format(decodeMs)}ms " +
                        "output->release=${"%.2f".format(releaseMs)}ms " +
                        "release->surface=${"%.2f".format(surfaceMs)}ms; " +
                        "capture->surface-render p50/p95/p99/max=" +
                        "${"%.1f".format(summary.p50Ms)}/" +
                        "${"%.1f".format(summary.p95Ms)}/" +
                        "${"%.1f".format(summary.p99Ms)}/" +
                        "${"%.1f".format(summary.maxMs)}ms n=${summary.count}",
                )
                if (pacing != null) {
                    diagLog(
                        "Frame pacing fps=${"%.2f".format(pacing.renderedFps)} " +
                            "inter-frame p50/p95/p99/max=" +
                            "${"%.2f".format(pacing.p50Ms)}/" +
                            "${"%.2f".format(pacing.p95Ms)}/" +
                            "${"%.2f".format(pacing.p99Ms)}/" +
                            "${"%.2f".format(pacing.maxMs)}ms " +
                            "std=${"%.2f".format(pacing.standardDeviationMs)}ms " +
                            "MAD=${"%.2f".format(pacing.medianAbsoluteDeviationMs)}ms " +
                            "duplicates=${pacing.duplicateFrames} " +
                            "skipped=${pacing.skippedFrames} " +
                            "reordered=${pacing.reorderedFrames}",
                    )
                }
            }
        }
    }

    private fun updateStats() {
        frameCount++
        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime
        if (elapsed >= 1000) {
            frameCount = 0
            droppedFrames = 0
            staleOutputDrops = 0
            lastStatsTime = now
        }
    }

    fun release() {
        isRunning = false
        try {
            availableInputBuffers.clear()
            pendingFrameTraces.clear()
            pendingSurfaceTraces.clear()
            decoder?.stop()
            decoder?.release()
            decoder = null
            decoderThread?.quitSafely()
            decoderThread = null
            decoderHandler = null
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val STALL_DETECT_INPUT_FRAMES = 120L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 1_000_000_000L
        private const val FORCE_KEYFRAME_REQUEST_INTERVAL_NS = 200_000_000L
        private const val INPUT_BUFFER_WAIT_MS = 8L
        private const val MAX_RENDER_LATENCY_NS = 100_000_000L
        private const val MAX_REASONABLE_LATENCY_NS = 2_000_000_000L
    }
}
