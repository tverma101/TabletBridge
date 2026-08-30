package com.sidescreen.app

import android.graphics.ImageFormat
import android.media.Image
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES31
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/**
 * CflRenderer — luma-guided chroma reconstruction ("CfL prediction") for the
 * 4:2:0 HEVC stream.
 *
 * WHY THIS EXISTS: the tablet's hardware decoder has no 4:4:4 path
 * (verified 2026-08-15), so chroma reaches Android at half resolution and
 * the default GPU YUV sampler's bilinear upsampling smears colored edges.
 * Luma arrives at full resolution, and on desktop UI luma and chroma are
 * strongly correlated — so chroma edges can be reconstructed from the luma
 * signal using the same "chroma from luma" least-squares idea HEVC/AV1 use
 * in-loop, applied in reverse at display time (after Artoriuz's
 * glsl-chroma-from-luma-prediction "lite" variant, adapted to co-sited
 * 4:2:0 and this pipeline).
 *
 * ARCHITECTURE: the decoder runs in ByteBuffer mode (surface=null) and
 * hands each decoded frame to [submitImage] as a CPU-readable Image with
 * REAL half-res chroma planes; this renderer uploads Y/UV into GL textures
 * and draws one fullscreen CfL pass to the SurfaceView's window surface.
 * An ImageReader-fed surface was tried first and is DEAD on this SoC:
 * Qualcomm's c2 decoder delivers UBWC/opaque graphic buffers whose plane
 * access is a FATAL JNI abort (nullptr NewDirectByteBuffer — see
 * 2026-08-16 notes), so the only plane source is codec.getOutputImage().
 *
 * Backpressure: submitImage blocks while one frame is still unconsumed
 * (max ~1 frame), mirroring the decoder's input-buffer backpressure.
 *
 * LIMITS: expects plain 8-bit-style YUV_420_888 planes; anything else fires
 * [onPlanesUnavailable] once so MainActivity can fall back to the direct
 * surface path.
 */
class CflRenderer {

    data class Stats(
        val cpuAvgMs: Double,
        val renderedFps: Double,
        val dropped: Long,
    ) {
        fun summary(): String =
            String.format(Locale.US, "CfL %.0ffps P%.1fms drop%d", renderedFps, cpuAvgMs, dropped)
    }

    var onStats: ((Stats) -> Unit)? = null

    /** Fired once when plane access fails (e.g. 10-bit PRIVATE buffers). */
    var onPlanesUnavailable: ((String) -> Unit)? = null

    /** Color range of the decoded planes: true = full (8-bit SCK capture),
     *  false = limited/video range (10-bit VideoRange capture). Wrong guess
     *  = lifted blacks / washed colors. Updated from the decoder's
     *  "color-range" MediaFormat value. */
    @Volatile private var fullRange = true

    fun setFullRange(full: Boolean) {
        DiagLog.log(TAG, "color range: ${if (full) "full" else "limited (video)"}")
        fullRange = full
    }

    /** Reconstruction strength 0..1 — how much luma-derived chroma detail to
     *  add back. 1.0 can overshoot (glossy/"shiny" edges: HEVC's own in-loop
     *  chroma smoothing means the true edge is softer than luma predicts).
     *  The conservative default is kept in PreferencesManager. */
    @Volatile private var strength = 0.15f
    @Volatile private var androidColorProfileEnabled = AndroidColorProfile.DEFAULT_ENABLED

    fun setStrength(s: Float) {
        val v = s.coerceIn(0f, 1f)
        DiagLog.log(TAG, "strength=$v")
        strength = v
    }

    fun setAndroidColorProfileEnabled(enabled: Boolean) {
        DiagLog.log(TAG, "androidColorProfile=$enabled")
        androidColorProfileEnabled = enabled
    }

    // --- GL objects ---
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var yTex = 0
    private var uvTex = 0 // semi-planar NV12 (RG)
    private var uTex = 0
    private var vTex = 0 // tri-planar fallback
    private var aPosLoc = -1
    private var aTexLoc = -1
    private var srcSizeLoc = -1
    private var fullRangeLoc = -1
    private var strengthLoc = -1
    private var androidColorProfileLoc = -1

    // --- stream geometry (luma = full res; chroma = half) ---
    @Volatile private var codedWidth = 0
    @Volatile private var codedHeight = 0
    private var semiPlanar = true
    private var texturesAllocated = false

    // --- frame source: decoder-fed images (ByteBuffer mode) ---
    private var pendingImage: Image? = null
    private var pendingConsumed: (() -> Unit)? = null

    // --- threading ---
    @Volatile private var running = false
    private val frameLock = Object()
    private var renderThread: Thread? = null

    // --- stats ---
    private val procNanos = LongArray(120)
    private var procIdx = 0
    private var procCount = 0
    private var statWindowStart = 0L
    private var statWindowFrames = 0L
    private val droppedFrames = AtomicLong(0)
    private var planesUnavailableSignalled = false

    private val vertexBuffer: FloatBuffer =
        ByteBuffer.allocateDirect(4 * 4 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            // x, y, u, v — image row 0 is at the TOP, GL origin is
            // bottom-left, so v is flipped.
            put(
                floatArrayOf(
                    -1f, -1f, 0f, 1f,
                    1f, -1f, 1f, 1f,
                    -1f, 1f, 0f, 0f,
                    1f, 1f, 1f, 0f,
                ),
            )
            position(0)
        }

    init {
        // no background threads needed — frames arrive via submitImage()
    }

    fun initialize(
        targetSurface: Surface,
        streamW: Int,
        streamH: Int,
    ) {
        if (streamW <= 0 || streamH <= 0) {
            throw IllegalStateException("CflRenderer: invalid stream size ${streamW}x$streamH")
        }

        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) throw IllegalStateException("eglGetDisplay failed")
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw IllegalStateException("eglInitialize failed")
        }
        val configAttribs =
            intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_NONE,
            )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0) || numConfigs[0] == 0) {
            throw IllegalStateException("eglChooseConfig failed")
        }
        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw IllegalStateException("eglCreateContext failed: ${EGL14.eglGetError()}")
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], targetSurface, intArrayOf(EGL14.EGL_NONE), 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw IllegalStateException("eglCreateWindowSurface failed: ${EGL14.eglGetError()}")
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("eglMakeCurrent failed: ${EGL14.eglGetError()}")
        }
        EGL14.eglSwapInterval(eglDisplay, 0)
        val qw = IntArray(1)
        val qh = IntArray(1)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_WIDTH, qw, 0)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_HEIGHT, qh, 0)
        surfaceW = qw[0]
        surfaceH = qh[0]

        program = buildProgram()
        if (program == 0) throw IllegalStateException("CfL program failed to link")
        aPosLoc = GLES31.glGetAttribLocation(program, "aPosition")
        aTexLoc = GLES31.glGetAttribLocation(program, "aTexCoord")
        srcSizeLoc = GLES31.glGetUniformLocation(program, "uSrcSize")
        fullRangeLoc = GLES31.glGetUniformLocation(program, "uFullRange")
        strengthLoc = GLES31.glGetUniformLocation(program, "uStrength")
        androidColorProfileLoc = GLES31.glGetUniformLocation(program, "uAndroidColorProfile")

        // VideoToolbox pads coded height to a 16-multiple (observed 1752 ->
        // 1760). Nothing to pre-allocate here — textures size themselves
        // from the first decoded Image.

        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)

        running = true
        statWindowStart = System.nanoTime()
        renderThread = Thread({ renderLoop() }, "CflRenderThread").also { it.start() }
        DiagLog.log(TAG, "init stream=${streamW}x$streamH surface=${surfaceW}x$surfaceH (decoder-fed)")
    }

    /**
     * Decoder hand-off (ByteBuffer mode). Blocks while a previous frame is
     * still unconsumed — bounded, natural backpressure. [onConsumed] runs on
     * the render thread after the uploads finish (the caller releases the
     * MediaCodec output buffer there).
     */
    fun submitImage(image: Image, onConsumed: () -> Unit) {
        // CRITICAL: on opaque buffers, touching .planes is a FATAL JNI abort
        // ("non-zero capacity for nullptr pointer" in nativeCreatePlanes) —
        // not catchable. getFormat() is safe and gates the access.
        if (image.format != ImageFormat.YUV_420_888) {
            DiagLog.log(TAG, "image format 0x${Integer.toHexString(image.format)} — not plane-accessible")
            signalPlanesUnavailable("image format 0x${Integer.toHexString(image.format)}")
            onConsumed()
            return
        }
        synchronized(frameLock) {
            while (running && pendingImage != null) {
                frameLock.wait()
            }
            if (!running) {
                onConsumed()
                return
            }
            pendingImage = image
            pendingConsumed = onConsumed
            frameLock.notify()
        }
    }

    // ===================== render loop =====================

    private fun renderLoop() {
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            DiagLog.log(TAG, "render thread: eglMakeCurrent failed")
            return
        }
        while (running) {
            val image: Image?
            val consumed: (() -> Unit)?
            synchronized(frameLock) {
                while (running && pendingImage == null) {
                    frameLock.wait()
                }
                image = pendingImage
                consumed = pendingConsumed
                pendingImage = null
                pendingConsumed = null
            }
            if (image == null || !running) {
                image?.close()
                consumed?.invoke()
                continue
            }
            val t0 = System.nanoTime()
            try {
                if (uploadPlanes(image)) {
                    drawFrame()
                }
            } catch (e: Exception) {
                DiagLog.log(TAG, "render error: ${e.message}")
            } finally {
                image.close()
                consumed?.invoke()
                // Wake a submitImage() blocked on backpressure.
                synchronized(frameLock) { frameLock.notifyAll() }
            }
            recordFrame(System.nanoTime() - t0)
        }
    }

    /** Returns false (and fires onPlanesUnavailable once) when the buffer is
     *  not plain 8-bit YUV_420_888. Callers must have verified
     *  image.format == YUV_420_888 first — .planes is fatal on PRIVATE. */
    private fun uploadPlanes(image: Image): Boolean {
        if (image.format != ImageFormat.YUV_420_888) {
            signalPlanesUnavailable("format 0x${Integer.toHexString(image.format)}")
            return false
        }
        val planes = image.planes
        if (planes.size < 3) {
            signalPlanesUnavailable("planes=${planes.size}")
            return false
        }
        val yP = planes[0]
        val uP = planes[1]
        if (yP.pixelStride != 1) {
            signalPlanesUnavailable("y pixelStride=${yP.pixelStride}")
            return false
        }
        if (uP.pixelStride != 1 && uP.pixelStride != 2) {
            signalPlanesUnavailable("u pixelStride=${uP.pixelStride}")
            return false
        }

        val w = image.width
        val h = image.height
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2

        if (!texturesAllocated || codedWidth != w || codedHeight != h || semiPlanar != (uP.pixelStride == 2)) {
            allocateTextures(w, h, cw, ch, semiPlanar = uP.pixelStride == 2)
        }

        GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
        GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, yTex)
        GLES31.glPixelStorei(GLES31.GL_UNPACK_ALIGNMENT, 1)
        GLES31.glPixelStorei(GLES31.GL_UNPACK_ROW_LENGTH, yP.rowStride)
        GLES31.glTexSubImage2D(GLES31.GL_TEXTURE_2D, 0, 0, 0, w, h, GLES31.GL_RED, GLES31.GL_UNSIGNED_BYTE, yP.buffer)

        if (semiPlanar) {
            GLES31.glActiveTexture(GLES31.GL_TEXTURE1)
            GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, uvTex)
            GLES31.glPixelStorei(GLES31.GL_UNPACK_ROW_LENGTH, uP.rowStride / 2)
            GLES31.glTexSubImage2D(GLES31.GL_TEXTURE_2D, 0, 0, 0, cw, ch, GLES31.GL_RG, GLES31.GL_UNSIGNED_BYTE, uP.buffer)
        } else {
            val vP = planes[2]
            GLES31.glActiveTexture(GLES31.GL_TEXTURE1)
            GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, uTex)
            GLES31.glPixelStorei(GLES31.GL_UNPACK_ROW_LENGTH, uP.rowStride)
            GLES31.glTexSubImage2D(GLES31.GL_TEXTURE_2D, 0, 0, 0, cw, ch, GLES31.GL_RED, GLES31.GL_UNSIGNED_BYTE, uP.buffer)
            GLES31.glActiveTexture(GLES31.GL_TEXTURE2)
            GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, vTex)
            GLES31.glPixelStorei(GLES31.GL_UNPACK_ROW_LENGTH, vP.rowStride)
            GLES31.glTexSubImage2D(GLES31.GL_TEXTURE_2D, 0, 0, 0, cw, ch, GLES31.GL_RED, GLES31.GL_UNSIGNED_BYTE, vP.buffer)
        }
        GLES31.glPixelStorei(GLES31.GL_UNPACK_ROW_LENGTH, 0)
        return true
    }

    private fun signalPlanesUnavailable(reason: String) {
        if (planesUnavailableSignalled) return
        planesUnavailableSignalled = true
        DiagLog.log(TAG, "planes unavailable ($reason) — CfL cannot run")
        onPlanesUnavailable?.invoke(reason)
    }

    private fun allocateTextures(w: Int, h: Int, cw: Int, ch: Int, semiPlanar: Boolean) {
        if (texturesAllocated) {
            val kill = intArrayOf(yTex, uvTex, uTex, vTex).filter { it != 0 }.toIntArray()
            if (kill.isNotEmpty()) GLES31.glDeleteTextures(kill.size, kill, 0)
        }
        this.semiPlanar = semiPlanar
        val n = if (semiPlanar) 2 else 3
        val tex = IntArray(n)
        GLES31.glGenTextures(n, tex, 0)
        yTex = tex[0]
        uvTex = if (semiPlanar) tex[1] else 0
        uTex = if (semiPlanar) 0 else tex[1]
        vTex = if (semiPlanar) 0 else tex[2]

        fun setup(id: Int, internalFormat: Int, tw: Int, th: Int) {
            GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, id)
            GLES31.glTexImage2D(
                GLES31.GL_TEXTURE_2D, 0, internalFormat, tw, th, 0,
                if (internalFormat == GLES31.GL_RG8) GLES31.GL_RG else GLES31.GL_RED,
                GLES31.GL_UNSIGNED_BYTE, null,
            )
            GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_MIN_FILTER, GLES31.GL_NEAREST)
            GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_MAG_FILTER, GLES31.GL_NEAREST)
            GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_WRAP_S, GLES31.GL_CLAMP_TO_EDGE)
            GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_WRAP_T, GLES31.GL_CLAMP_TO_EDGE)
        }
        setup(yTex, GLES31.GL_R8, w, h)
        if (semiPlanar) {
            setup(uvTex, GLES31.GL_RG8, cw, ch)
        } else {
            setup(uTex, GLES31.GL_R8, cw, ch)
            setup(vTex, GLES31.GL_R8, cw, ch)
        }
        GLES31.glUseProgram(program)
        GLES31.glUniform1i(GLES31.glGetUniformLocation(program, "uY"), 0)
        if (semiPlanar) {
            GLES31.glUniform1i(GLES31.glGetUniformLocation(program, "uUV"), 1)
        } else {
            GLES31.glUniform1i(GLES31.glGetUniformLocation(program, "uU"), 1)
            GLES31.glUniform1i(GLES31.glGetUniformLocation(program, "uV"), 2)
        }
        GLES31.glUniform1i(GLES31.glGetUniformLocation(program, "uSemiPlanar"), if (semiPlanar) 1 else 0)
        codedWidth = w
        codedHeight = h
        texturesAllocated = true
        DiagLog.log(TAG, "textures ${w}x${h} chroma ${cw}x${ch} semiPlanar=$semiPlanar")
    }

    private var surfaceW = 0
    private var surfaceH = 0

    private fun drawFrame() {
        GLES31.glViewport(0, 0, surfaceW, surfaceH)
        GLES31.glUseProgram(program)
        GLES31.glUniform2f(srcSizeLoc, codedWidth.toFloat(), codedHeight.toFloat())
        GLES31.glUniform1i(fullRangeLoc, if (fullRange) 1 else 0)
        GLES31.glUniform1f(strengthLoc, strength)
        GLES31.glUniform1i(androidColorProfileLoc, if (androidColorProfileEnabled) 1 else 0)
        GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
        GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, yTex)
        GLES31.glActiveTexture(GLES31.GL_TEXTURE1)
        GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, if (semiPlanar) uvTex else uTex)
        if (!semiPlanar) {
            GLES31.glActiveTexture(GLES31.GL_TEXTURE2)
            GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, vTex)
        }

        GLES31.glEnableVertexAttribArray(aPosLoc)
        GLES31.glEnableVertexAttribArray(aTexLoc)
        vertexBuffer.position(0)
        GLES31.glVertexAttribPointer(aPosLoc, 2, GLES31.GL_FLOAT, false, 16, vertexBuffer)
        vertexBuffer.position(2)
        GLES31.glVertexAttribPointer(aTexLoc, 2, GLES31.GL_FLOAT, false, 16, vertexBuffer)
        GLES31.glDrawArrays(GLES31.GL_TRIANGLE_STRIP, 0, 4)
        GLES31.glDisableVertexAttribArray(aPosLoc)
        GLES31.glDisableVertexAttribArray(aTexLoc)

        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
    }

    private fun recordFrame(nanos: Long) {
        procNanos[procIdx % procNanos.size] = nanos
        procIdx++
        procCount++
        statWindowFrames++
        val now = System.nanoTime()
        val windowNs = now - statWindowStart
        if (statWindowFrames >= 60 && windowNs > 0) {
            val filled = minOf(procCount.toLong(), procNanos.size.toLong()).toInt()
            var sum = 0.0
            for (i in 0 until filled) sum += procNanos[i].toDouble()
            val cpuAvg = sum / filled / 1_000_000.0
            val fps = statWindowFrames * 1_000_000_000.0 / windowNs
            onStats?.invoke(Stats(cpuAvg, fps, droppedFrames.get()))
            statWindowFrames = 0
            statWindowStart = now
        }
    }

    fun release() {
        running = false
        synchronized(frameLock) {
            pendingImage?.close()
            pendingImage = null
            pendingConsumed?.invoke()
            pendingConsumed = null
            frameLock.notifyAll()
        }
        try {
            renderThread?.join(800)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        renderThread = null
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
            if (program != 0) GLES31.glDeleteProgram(program)
            val kill = intArrayOf(yTex, uvTex, uTex, vTex).filter { it != 0 }.toIntArray()
            if (kill.isNotEmpty()) GLES31.glDeleteTextures(kill.size, kill, 0)
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglTerminate(eglDisplay)
        }
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
        program = 0
        yTex = 0
        uvTex = 0
        uTex = 0
        vTex = 0
        texturesAllocated = false
        DiagLog.log(TAG, "released")
    }

    // ===================== shaders =====================

    private val vertexShader =
        """
        #version 310 es
        in vec4 aPosition;
        in vec4 aTexCoord;
        out vec2 vTexCoord;
        void main() {
            gl_Position = aPosition;
            vTexCoord = aTexCoord.xy;
        }
        """.trimIndent()

    /**
     * CfL prediction (lite): bilinear chroma plus alpha-scaled luma detail.
     *   C(p) = C_bilinear(p) + a * (Y(p) - Y_up(p))
     * Y_up is the luma downsampled to chroma sites (2x2 average — the
     * subsampling kernel) and re-upsampled with the SAME bilinear kernel as
     * C_bilinear; a is the per-channel least-squares slope between chroma
     * and luma over the four bilinear chroma taps, clamped to [-1, 1].
     * Co-sited (type-0) chroma assumed — chroma texel (cx,cy) represents
     * luma (2cx,2cy) — matching the hardware compositor's assumption.
     * Output matrix: BT.709 full-range (matches the SCK 420f capture).
     */
    private val fragmentShader =
        """
        #version 310 es
        precision highp float;
        precision highp int;
        in vec2 vTexCoord;
        uniform sampler2D uY;    // R8, full res
        uniform sampler2D uUV;   // RG8 NV12 (semi-planar)
        uniform sampler2D uU;    // R8 planar
        uniform sampler2D uV;    // R8 planar
        uniform int uSemiPlanar;
        uniform int uFullRange;
        uniform float uStrength;
        uniform vec2 uSrcSize;
        out vec4 fragColor;

        ${AndroidColorProfile.GLSL_FUNCTION}

        float fetchY(ivec2 p) {
            p = clamp(p, ivec2(0), ivec2(uSrcSize) - 1);
            return texelFetch(uY, p, 0).r;
        }
        vec2 fetchC(ivec2 c) {
            ivec2 cm = clamp(c, ivec2(0), ivec2(uSrcSize) / 2 - 1);
            if (uSemiPlanar == 1) return texelFetch(uUV, cm, 0).rg;
            return vec2(texelFetch(uU, cm, 0).r, texelFetch(uV, cm, 0).r);
        }
        float blockY(ivec2 c) {
            ivec2 p = 2 * c;
            return 0.25 * (fetchY(p) + fetchY(p + ivec2(1,0))
                         + fetchY(p + ivec2(0,1)) + fetchY(p + ivec2(1,1)));
        }

        void main() {
            vec2 fpx = vTexCoord * uSrcSize;
            ivec2 p = ivec2(floor(fpx));
            vec2 cf = fpx * 0.5;
            ivec2 c0 = ivec2(floor(cf));
            vec2 fr = cf - vec2(c0);

            vec2 c00 = fetchC(c0);
            vec2 c10 = fetchC(c0 + ivec2(1,0));
            vec2 c01 = fetchC(c0 + ivec2(0,1));
            vec2 c11 = fetchC(c0 + ivec2(1,1));
            vec2 cBil = mix(mix(c00, c10, fr.x), mix(c01, c11, fr.x), fr.y);

            float y00 = blockY(c0);
            float y10 = blockY(c0 + ivec2(1,0));
            float y01 = blockY(c0 + ivec2(0,1));
            float y11 = blockY(c0 + ivec2(1,1));
            float yUp = mix(mix(y00, y10, fr.x), mix(y01, y11, fr.x), fr.y);

            vec2 cMean = 0.25 * (c00 + c10 + c01 + c11);
            float yMean = 0.25 * (y00 + y10 + y01 + y11);
            vec2 num = (c00 - cMean) * (y00 - yMean)
                     + (c10 - cMean) * (y10 - yMean)
                     + (c01 - cMean) * (y01 - yMean)
                     + (c11 - cMean) * (y11 - yMean);
            float den = (y00 - yMean) * (y00 - yMean)
                      + (y10 - yMean) * (y10 - yMean)
                      + (y01 - yMean) * (y01 - yMean)
                      + (y11 - yMean) * (y11 - yMean);
            vec2 a = clamp(num / max(vec2(den), vec2(1e-5)), vec2(-1.0), vec2(1.0));

            float Y = fetchY(p);
            vec2 C = clamp(cBil + uStrength * a * (Y - yUp), vec2(0.0), vec2(1.0));

            vec3 rgb;
            if (uFullRange == 1) {
                // BT.709 full range (matches SCK's 420f capture)
                float Cb = C.x - 0.5;
                float Cr = C.y - 0.5;
                rgb = vec3(Y + 1.5748 * Cr,
                           Y - 0.1873 * Cb - 0.4681 * Cr,
                           Y + 1.8556 * Cb);
            } else {
                // BT.709 limited range (10-bit VideoRange capture path):
                // expand studio-swing then convert — reading limited as
                // full lifts the blacks (the "washed colors" bug).
                float y = (Y - 16.0 / 255.0) * (255.0 / 219.0);
                float cb = (C.x - 16.0 / 255.0) * (255.0 / 224.0) - 0.5;
                float cr = (C.y - 16.0 / 255.0) * (255.0 / 224.0) - 0.5;
                rgb = vec3(1.16438 * y + 1.59603 * cr,
                           1.16438 * y - 0.39176 * cb - 0.81297 * cr,
                           1.16438 * y + 2.01723 * cb);
            }
            fragColor = vec4(applyAndroidColorProfile(clamp(rgb, 0.0, 1.0)), 1.0);
        }
        """.trimIndent()

    private fun buildProgram(): Int {
        val vs = compileShader(GLES31.GL_VERTEX_SHADER, vertexShader)
        if (vs == 0) return 0
        val fs = compileShader(GLES31.GL_FRAGMENT_SHADER, fragmentShader)
        if (fs == 0) {
            GLES31.glDeleteShader(vs)
            return 0
        }
        val p = GLES31.glCreateProgram()
        GLES31.glAttachShader(p, vs)
        GLES31.glAttachShader(p, fs)
        GLES31.glLinkProgram(p)
        val ok = IntArray(1)
        GLES31.glGetProgramiv(p, GLES31.GL_LINK_STATUS, ok, 0)
        GLES31.glDeleteShader(vs)
        GLES31.glDeleteShader(fs)
        if (ok[0] == 0) {
            DiagLog.log(TAG, "link failed: ${GLES31.glGetProgramInfoLog(p)}")
            GLES31.glDeleteProgram(p)
            return 0
        }
        return p
    }

    private fun compileShader(type: Int, src: String): Int {
        val s = GLES31.glCreateShader(type)
        GLES31.glShaderSource(s, src)
        GLES31.glCompileShader(s)
        val ok = IntArray(1)
        GLES31.glGetShaderiv(s, GLES31.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            DiagLog.log(TAG, "compile failed: ${GLES31.glGetShaderInfoLog(s)}")
            GLES31.glDeleteShader(s)
            return 0
        }
        return s
    }

    private companion object {
        const val TAG = "CfL"
    }
}
