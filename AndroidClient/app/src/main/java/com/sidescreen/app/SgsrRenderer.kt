package com.sidescreen.app

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLES31
import android.view.Surface
import java.io.BufferedReader
import java.io.InputStreamReader
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.Locale
import kotlin.math.abs

/**
 * GPU post-processing bridge between MediaCodec and the display surface.
 *
 * Two-pass OpenGL ES 3 pipeline (Kotlin port of Moonlight's GlesPassthroughBridge, PR #1567,
 * adapted for SideScreen's MediaCodec -> Surface architecture):
 *
 *   Pass 1: samplerExternalOES (hardware decoder output) -> standard 2D texture via FBO.
 *   Pass 2: post shader (SGSR1 / CAS / plain bridge copy) -> display surface.
 *
 * Rules honored (per campaign brief):
 *   - No CPU pixel readback, no Bitmap, no per-pixel JVM loops, no extra codec.
 *   - Frames stay on the GPU; textures/FBOs preallocated; shaders compiled once.
 *   - Dedicated render thread + own EGL context; swap interval 0 (no added vsync wait).
 *     An optional render-side cadence cap is used only by the experimental USB
 *     color bridge, so it can stay at a stable 60 FPS without queueing frames.
 *   - Drain-to-latest: if the decoder outpaces the GPU, intermediate frames are consumed
 *     and dropped; only the freshest complete frame is rendered.
 *   - CPU + GPU (EXT_disjoint_timer_query, when available) postprocess timing.
 */
class SgsrRenderer(
    private val context: Context,
    frameRateCap: Int? = null,
) : SurfaceTexture.OnFrameAvailableListener {

    enum class Mode {
        BRIDGE_ONLY, // OES->2D bridge only (isolates bridge cost from shader cost)
        SGSR1,       // Snapdragon Game Super Resolution 1, edge-direction variant
        CAS;         // AMD FidelityFX CAS, sharpen-only (native-resolution use)

        companion object {
            fun from(name: String?): Mode {
                val n = name?.trim()?.uppercase()?.replace("_", "")?.replace("-", "") ?: return SGSR1
                return when {
                    n.contains("BRIDGE") -> BRIDGE_ONLY
                    n.contains("CAS") -> CAS
                    n.contains("SGSR") -> SGSR1
                    else -> SGSR1
                }
            }
        }
    }

    data class Stats(
        val mode: Mode,
        val cpuAvgMs: Double,
        val cpuP95Ms: Double,
        val gpuMs: Double,
        val backlog: Long,
        val renderedFps: Double,
    ) {
        fun summary(): String =
            String.format(
                Locale.US,
                "%s %.0ffps PP%.1fms G%.1f bk%d",
                mode.name,
                renderedFps,
                cpuAvgMs,
                gpuMs,
                backlog,
            )
    }

    /** Invoked from the render thread every STAT_WINDOW frames. */
    var onStats: ((Stats) -> Unit)? = null

    // --- Pass 1 shaders (OES -> 2D), identical to the Moonlight donor ---
    private val BLIT_VERTEX_SHADER =
        "#version 310 es\n" +
            "uniform mat4 uSTMatrix;\n" +
            "in vec4 aPosition;\n" +
            "in vec4 aTexCoord;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "  gl_Position = aPosition;\n" +
            "  vTexCoord = (uSTMatrix * aTexCoord).xy;\n" +
            "}\n"

    private val BLIT_FRAGMENT_SHADER =
        "#version 310 es\n" +
            "#extension GL_OES_EGL_image_external_essl3 : require\n" +
            "precision mediump float;\n" +
            "in vec2 vTexCoord;\n" +
            "uniform samplerExternalOES sTexture;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  fragColor = texture(sTexture, vTexCoord);\n" +
            "}\n"

    /**
     * Exact-size bridge path. Sampling the decoder's external texture directly
     * avoids the intermediate RGBA texture and second texture lookup used by
     * the general scaler path. The transform is still applied by the shared
     * blit vertex shader so SurfaceTexture orientation/crop behavior is kept.
     */
    private val DIRECT_BRIDGE_POST_FRAGMENT_SHADER =
        "#version 310 es\n" +
            "#extension GL_OES_EGL_image_external_essl3 : require\n" +
            "precision mediump float;\n" +
            "in vec2 vTexCoord;\n" +
            "uniform samplerExternalOES sTexture;\n" +
            AndroidColorProfile.GLSL_FUNCTION + "\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  vec3 color = texture(sTexture, vTexCoord).rgb;\n" +
            "  fragColor = vec4(applyAndroidColorProfile(color), 1.0);\n" +
            "}\n"

    private val POST_VERTEX_SHADER_PREFIX =
        "#version 310 es\n"

    private val POST_VERTEX_SHADER_BODY =
        "in vec4 aPosition;\n" +
            "in vec4 aTexCoord;\n" +
            "out vec2 v_texCoord;\n" +
            "out vec2 v_imgCoord;\n" +
            "void main() {\n" +
            "  gl_Position = aPosition;\n" +
            "  v_texCoord = aTexCoord.xy;\n" +
            "  v_imgCoord = (aTexCoord.xy * vec2(SRC_W, SRC_H)) + vec2(-0.5, 0.5);\n" +
            "}\n"

    private val BRIDGE_POST_FRAGMENT_SHADER =
        "#version 310 es\n" +
            "precision mediump float;\n" +
            "in vec2 v_texCoord;\n" +
            "uniform sampler2D ps0;\n" +
            AndroidColorProfile.GLSL_FUNCTION + "\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  vec3 color = texture(ps0, v_texCoord).rgb;\n" +
            "  fragColor = vec4(applyAndroidColorProfile(color), 1.0);\n" +
            "}\n"

    /**
     * Catmull-Rom bicubic final scaler for the experimental bridge. It is
     * selected only when the EGL window is larger than the decoded texture;
     * exact-size 2800x1752 output keeps the one-sample bridge path.
     */
    private val BICUBIC_BRIDGE_POST_FRAGMENT_SHADER =
        "#version 310 es\n" +
            "precision highp float;\n" +
            "in vec2 v_texCoord;\n" +
            "uniform sampler2D ps0;\n" +
            AndroidColorProfile.GLSL_FUNCTION + "\n" +
            "precision highp float;\n" +
            "out vec4 fragColor;\n" +
            "float cubicWeight(float x) {\n" +
            "  float a = abs(x);\n" +
            "  if (a <= 1.0) return 1.5 * a * a * a - 2.5 * a * a + 1.0;\n" +
            "  if (a < 2.0) return -0.5 * a * a * a + 2.5 * a * a - 4.0 * a + 2.0;\n" +
            "  return 0.0;\n" +
            "}\n" +
            "vec3 sampleBicubic(vec2 uv) {\n" +
            "  highp vec2 source = uv * vec2(SRC_W, SRC_H) - vec2(0.5);\n" +
            "  highp vec2 base = floor(source);\n" +
            "  highp vec2 fraction = source - base;\n" +
            "  vec3 color = vec3(0.0);\n" +
            "  float total = 0.0;\n" +
            "  for (int y = -1; y <= 2; y++) {\n" +
            "    float wy = cubicWeight(float(y) - fraction.y);\n" +
            "    for (int x = -1; x <= 2; x++) {\n" +
            "      float weight = wy * cubicWeight(float(x) - fraction.x);\n" +
            "      highp vec2 sampleCoord = (base + vec2(float(x), float(y)) + vec2(0.5)) * " +
            "vec2(INV_SRC_W, INV_SRC_H);\n" +
            "      color += texture(ps0, clamp(sampleCoord, vec2(0.0), vec2(1.0))).rgb * weight;\n" +
            "      total += weight;\n" +
            "    }\n" +
            "  }\n" +
            "  return color / max(total, 0.0001);\n" +
            "}\n" +
            "void main() {\n" +
            "  vec3 color = clamp(sampleBicubic(v_texCoord), 0.0, 1.0);\n" +
            "  fragColor = vec4(applyAndroidColorProfile(color), 1.0);\n" +
            "}\n"

    // AMD FidelityFX CAS, sharpen-only (noScaling) + better diagonals, per
    // https://github.com/GPUOpen-Effects/FidelityFX-CAS (MIT). Green-channel
    // coefficient fast path, as in the reference CasFilter().
    private val CAS_POST_FRAGMENT_SHADER =
        "#version 310 es\n" +
            "precision mediump float;\n" +
            "in vec2 v_texCoord;\n" +
            "uniform sampler2D ps0;\n" +
            "uniform float uSharpness;\n" +
            AndroidColorProfile.GLSL_FUNCTION + "\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  vec2 px = vec2(INV_SRC_W, INV_SRC_H);\n" +
            "  vec3 a = texture(ps0, v_texCoord + vec2(-px.x, -px.y)).rgb;\n" +
            "  vec3 b = texture(ps0, v_texCoord + vec2(0.0, -px.y)).rgb;\n" +
            "  vec3 c = texture(ps0, v_texCoord + vec2(px.x, -px.y)).rgb;\n" +
            "  vec3 d = texture(ps0, v_texCoord + vec2(-px.x, 0.0)).rgb;\n" +
            "  vec3 e = texture(ps0, v_texCoord).rgb;\n" +
            "  vec3 f = texture(ps0, v_texCoord + vec2(px.x, 0.0)).rgb;\n" +
            "  vec3 g = texture(ps0, v_texCoord + vec2(-px.x, px.y)).rgb;\n" +
            "  vec3 h = texture(ps0, v_texCoord + vec2(0.0, px.y)).rgb;\n" +
            "  vec3 i = texture(ps0, v_texCoord + vec2(px.x, px.y)).rgb;\n" +
            "  vec3 mn = min(min(min(d, e), min(f, b)), h);\n" +
            "  vec3 mn2 = min(mn, min(min(a, c), min(g, i)));\n" +
            "  mn += mn2;\n" +
            "  vec3 mx = max(max(max(d, e), max(f, b)), h);\n" +
            "  vec3 mx2 = max(mx, max(max(a, c), max(g, i)));\n" +
            "  mx += mx2;\n" +
            "  vec3 amp = clamp(min(mn, 2.0 - mx) / mx, 0.0, 1.0);\n" +
            "  amp = sqrt(amp);\n" +
            "  float peak = -1.0 / mix(8.0, 5.0, clamp(uSharpness, 0.0, 1.0));\n" +
            "  float wG = amp.g * peak;\n" +
            "  float rcpWeight = 1.0 / (1.0 + 4.0 * wG);\n" +
            "  vec3 color = clamp((b + d + f + h) * wG + e, 0.0, 1.0) * rcpWeight;\n" +
            "  fragColor = vec4(applyAndroidColorProfile(clamp(color, 0.0, 1.0)), 1.0);\n" +
            "}\n"

    // EGL state
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // Programs / GL objects
    private var blitProgram = 0
    private var postProgram = 0
    private var oesTextureId = 0
    private var fboTextureId = 0
    private var fboId = 0

    private var surfaceTexture: SurfaceTexture? = null
    private var decoderSurface: Surface? = null
    private val transformMatrix = FloatArray(16)

    private var streamWidth = 0
    private var streamHeight = 0
    private var displayWidth = 0
    private var displayHeight = 0

    // Handles
    private var blitUstMatrix = -1
    private var blitAPos = -1
    private var blitATex = -1
    private var blitSTex = -1
    private var postAPos = -1
    private var postATex = -1
    private var postSTex = -1
    private var postUstMatrix = -1
    private var postSharpness = -1
    private var postColorProfile = -1
    private var postUsesExternalTexture = false

    private val vertexBuffer: FloatBuffer

    // Threading
    @Volatile private var running = false
    private val frameLock = Object()
    @Volatile private var frameAvailable = false
    @Volatile private var forceRender = false
    private var renderThread: Thread? = null
    private val framePacer = FramePacer(frameRateCap)

    // Post program params (applied on the render thread via dirty flags)
    @Volatile private var mode = Mode.SGSR1
    @Volatile private var sharpness = 0.8f
    @Volatile private var edgeThreshold = 8.0f / 255.0f
    @Volatile private var colorProfileEnabled = AndroidColorProfile.DEFAULT_ENABLED
    @Volatile private var fullRange = true
    @Volatile private var programDirty = false
    @Volatile private var pendingMode: Mode? = null
    @Volatile private var pendingSharpness: Float? = null
    @Volatile private var pendingEdgeThreshold: Float? = null
    @Volatile private var resizeDirty = false
    private var pendingStreamW = 0
    private var pendingStreamH = 0

    // Timing
    private var gpuTimerSupported = false
    private var gpuQuery = 0
    private var gpuQueryPending = false
    private var lastGpuMs = Double.NaN
    private val cpuRing = LongArray(600)
    private var cpuRingIdx = 0
    private var cpuRingCount = 0
    private var statFrameCount = 0
    private var statBacklogSum = 0L
    private var statWindowStart = System.nanoTime()

    private val vertices =
        floatArrayOf(
            -1.0f, -1.0f, 0.0f, 0.0f, // bottom-left
            1.0f, -1.0f, 1.0f, 0.0f, // bottom-right
            -1.0f, 1.0f, 0.0f, 1.0f, // top-left
            1.0f, 1.0f, 1.0f, 1.0f, // top-right
        )

    init {
        vertexBuffer =
            ByteBuffer
                .allocateDirect(vertices.size * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
        vertexBuffer.put(vertices).position(0)
    }

    // ===================== PUBLIC API =====================

    /**
     * Creates the EGL/GL state and starts the render thread. Must be called with a valid
     * display surface (SurfaceView holder surface or TextureView surface) and the incoming
     * stream resolution. Throws on EGL failure so the caller can fall back to direct rendering.
     */
    @Throws(IllegalStateException::class)
    fun initialize(
        targetSurface: Surface,
        streamW: Int,
        streamH: Int,
    ) {
        if (streamW <= 0 || streamH <= 0) {
            throw IllegalStateException("SgsrRenderer: invalid stream size ${streamW}x$streamH")
        }
        streamWidth = streamW
        streamHeight = streamH

        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
            throw IllegalStateException("eglGetDisplay failed")
        }
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
            throw IllegalStateException("eglChooseConfig failed (n=${numConfigs[0]})")
        }

        val ctxAttribs =
            intArrayOf(
                EGL14.EGL_CONTEXT_CLIENT_VERSION, 3,
                EGL14.EGL_NONE,
            )
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            throw IllegalStateException("eglCreateContext failed: ${EGL14.eglGetError()}")
        }

        eglSurface =
            EGL14.eglCreateWindowSurface(eglDisplay, configs[0], targetSurface, intArrayOf(EGL14.EGL_NONE), 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            throw IllegalStateException("eglCreateWindowSurface failed: ${EGL14.eglGetError()}")
        }

        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("eglMakeCurrent failed: ${EGL14.eglGetError()}")
        }

        // No added vsync wait: frames are pushed to the compositor as soon as the GPU is done.
        EGL14.eglSwapInterval(eglDisplay, 0)

        val queryW = IntArray(1)
        val queryH = IntArray(1)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_WIDTH, queryW, 0)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_HEIGHT, queryH, 0)
        displayWidth = queryW[0]
        displayHeight = queryH[0]

        val ext = GLES30.glGetString(GLES30.GL_EXTENSIONS) ?: ""
        gpuTimerSupported = ext.contains("GL_EXT_disjoint_timer_query")
        if (gpuTimerSupported) {
            val q = IntArray(1)
            GLES30.glGenQueries(1, q, 0)
            gpuQuery = q[0]
        }
        DiagLog.log("SGSR", "init stream=${streamWidth}x$streamHeight display=${displayWidth}x$displayHeight " +
            "gpuTimer=$gpuTimerSupported frameCap=${framePacer.targetFps ?: "off"} " +
            "gl=${GLES30.glGetString(GLES30.GL_VERSION)}")

        // Pass 1 program
        blitProgram = createProgram(BLIT_VERTEX_SHADER, BLIT_FRAGMENT_SHADER)
        if (blitProgram == 0) throw IllegalStateException("blit program failed to link")
        blitUstMatrix = GLES31.glGetUniformLocation(blitProgram, "uSTMatrix")
        blitAPos = GLES31.glGetAttribLocation(blitProgram, "aPosition")
        blitATex = GLES31.glGetAttribLocation(blitProgram, "aTexCoord")
        blitSTex = GLES31.glGetUniformLocation(blitProgram, "sTexture")

        // Pass 2 program
        compilePostProgram()

        // Textures
        val textures = IntArray(2)
        GLES31.glGenTextures(2, textures, 0)
        oesTextureId = textures[0]
        fboTextureId = textures[1]

        GLES31.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES31.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES31.GL_TEXTURE_MIN_FILTER, GLES31.GL_NEAREST.toFloat())
        GLES31.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES31.GL_TEXTURE_MAG_FILTER, GLES31.GL_NEAREST.toFloat())
        GLES31.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES31.GL_TEXTURE_WRAP_S, GLES31.GL_CLAMP_TO_EDGE)
        GLES31.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES31.GL_TEXTURE_WRAP_T, GLES31.GL_CLAMP_TO_EDGE)

        GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, fboTextureId)
        GLES31.glTexImage2D(
            GLES31.GL_TEXTURE_2D, 0, GLES31.GL_RGBA, streamWidth, streamHeight, 0,
            GLES31.GL_RGBA, GLES31.GL_UNSIGNED_BYTE, null,
        )
        // The post shaders perform their own sampling. Linear filtering here
        // would blur the intermediate texture once before CAS/SGSR or the
        // explicit bicubic scaler samples it again. Nearest preserves the
        // decoded pixel grid for exact-size USB output and keeps the bicubic
        // bridge a true 16-tap reconstruction instead of a double filter.
        GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_MIN_FILTER, GLES31.GL_NEAREST)
        GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_MAG_FILTER, GLES31.GL_NEAREST)
        GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_WRAP_S, GLES31.GL_CLAMP_TO_EDGE)
        GLES31.glTexParameteri(GLES31.GL_TEXTURE_2D, GLES31.GL_TEXTURE_WRAP_T, GLES31.GL_CLAMP_TO_EDGE)

        // FBO
        val fbos = IntArray(1)
        GLES31.glGenFramebuffers(1, fbos, 0)
        fboId = fbos[0]
        GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, fboId)
        GLES31.glFramebufferTexture2D(
            GLES31.GL_FRAMEBUFFER, GLES31.GL_COLOR_ATTACHMENT0, GLES31.GL_TEXTURE_2D, fboTextureId, 0,
        )
        val status = GLES31.glCheckFramebufferStatus(GLES31.GL_FRAMEBUFFER)
        if (status != GLES31.GL_FRAMEBUFFER_COMPLETE) {
            throw IllegalStateException("FBO incomplete: 0x${Integer.toHexString(status)}")
        }
        GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)

        // SurfaceTexture fed by MediaCodec
        surfaceTexture = SurfaceTexture(oesTextureId)
        surfaceTexture?.setOnFrameAvailableListener(this)
        decoderSurface = Surface(surfaceTexture)

        // Hand the context over to the render thread
        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)

        running = true
        renderThread = Thread({ renderLoop() }, "SgsrRenderThread").also { it.start() }
        DiagLog.log("SGSR", "bridge initialized")
    }

    /** The surface MediaCodec must decode into. */
    val decoderSurfaceRef: Surface?
        get() = decoderSurface

    fun setMode(m: Mode) {
        pendingMode = m
        programDirty = true
        requestRender()
    }

    fun setSharpness(s: Float) {
        pendingSharpness = s.coerceIn(0f, 1f)
        programDirty = true
        requestRender()
    }

    fun setEdgeThreshold(t: Float) {
        pendingEdgeThreshold = t.coerceIn(0f, 1f)
        programDirty = true
        requestRender()
    }

    fun setAndroidColorProfileEnabled(enabled: Boolean) {
        colorProfileEnabled = enabled
        requestRender()
    }

    /**
     * The calibrated Android sRGB tone curve is for the 8-bit full-range USB
     * path. Main10 VideoRange already lands close to the native Android chart;
     * keep the profile uniform off for that negotiated range.
     */
    fun setFullRange(full: Boolean) {
        fullRange = full
        requestRender()
    }

    /**
     * Called when the decoder reports its real output size (SPS-driven). The crop rect is
     * deliberately IGNORED: the QTI decoder on this tablet reports crop in rotated
     * coordinates (observed: 0,2799,0,1751 for a 2800x1760 landscape stream) and pre-crops
     * the surface output itself, so the coded dims are the effective texture size
     * (verified empirically — proportions render correctly at coded dims).
     * Thread-safe — applied on the render thread.
     */
    fun resizeStream(
        w: Int,
        h: Int,
        cropL: Int,
        cropR: Int,
        cropT: Int,
        cropB: Int,
    ) {
        if (w <= 0 || h <= 0) return
        pendingStreamW = w
        pendingStreamH = h
        resizeDirty = true
        requestRender()
    }

    fun release() {
        running = false
        synchronized(frameLock) { frameLock.notifyAll() }
        renderThread?.join(1500)
        renderThread = null
        onStats = null
    }

    // ===================== SurfaceTexture.OnFrameAvailableListener =====================

    override fun onFrameAvailable(st: SurfaceTexture) {
        synchronized(frameLock) {
            frameAvailable = true
            frameLock.notifyAll()
        }
    }

    private fun requestRender() {
        synchronized(frameLock) {
            forceRender = true
            frameLock.notifyAll()
        }
    }

    // ===================== RENDER THREAD =====================

    private fun renderLoop() {
        val st = surfaceTexture ?: return teardownGl()
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            DiagLog.log("SGSR", "render thread eglMakeCurrent failed: ${EGL14.eglGetError()}")
            return teardownGl()
        }
        while (running) {
            synchronized(frameLock) {
                while (!frameAvailable && !forceRender && running) {
                    try {
                        frameLock.wait(100)
                    } catch (e: InterruptedException) {
                        return teardownGl()
                    }
                }
                forceRender = false
            }
            if (!running) break

            // Drain-to-latest: consume every queued decoder frame, render only the newest.
            var backlog = 0L
            while (backlog < MAX_DRAIN) {
                val hasFrame =
                    synchronized(frameLock) {
                        if (frameAvailable) {
                            frameAvailable = false
                            true
                        } else {
                            false
                        }
                    }
                if (!hasFrame) break
                st.updateTexImage()
                backlog++
            }
            if (!waitForPresentationSlot()) break
            if (backlog > 0) {
                renderFrame(backlog - 1)
            } else {
                // forceRender with no new decoder frame: re-render the current texture
                // (mode / sharpness / threshold changed).
                renderFrame(0)
            }
        }
        teardownGl()
    }

    private fun waitForPresentationSlot(): Boolean {
        while (running) {
            val waitNs = framePacer.delayNanos(System.nanoTime())
            if (waitNs <= 0L) {
                framePacer.markSlotStarted(System.nanoTime())
                return true
            }
            try {
                Thread.sleep(waitNs / 1_000_000L, (waitNs % 1_000_000L).toInt())
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return false
    }

    private fun renderFrame(backlog: Long) {
        val st = surfaceTexture ?: return
        st.getTransformMatrix(transformMatrix)

        val cpuStart = System.nanoTime()

        // Fetch the previous frame's GPU time without stalling (query results are
        // typically ready by the next frame).
        if (gpuTimerSupported && gpuQueryPending) {
            val avail = IntArray(1)
            GLES30.glGetQueryObjectuiv(gpuQuery, GL_QUERY_RESULT_AVAILABLE_EXT, avail, 0)
            if (avail[0] != 0) {
                val result = IntArray(1)
                GLES30.glGetQueryObjectuiv(gpuQuery, GL_QUERY_RESULT_EXT, result, 0)
                lastGpuMs = Integer.toUnsignedLong(result[0]) / 1_000_000.0
                gpuQueryPending = false
            }
        }

        if (programDirty) {
            applyPendingPostParams()
        }

        if (resizeDirty) {
            resizeDirty = false
            val w = pendingStreamW
            val h = pendingStreamH
            if (w != streamWidth || h != streamHeight) {
                streamWidth = w
                streamHeight = h
                GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, fboTextureId)
                GLES31.glTexImage2D(
                    GLES31.GL_TEXTURE_2D, 0, GLES31.GL_RGBA, streamWidth, streamHeight, 0,
                    GLES31.GL_RGBA, GLES31.GL_UNSIGNED_BYTE, null,
                )
                GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, 0)
                compilePostProgram()
                DiagLog.log("SGSR", "stream size changed to ${streamWidth}x$streamHeight")
            }
        }

        if (gpuTimerSupported) {
            GLES30.glBeginQuery(GL_TIME_ELAPSED_EXT, gpuQuery)
        }

        if (postUsesExternalTexture) {
            // Exact-size bridge: keep the decoder's external texture in the
            // single output pass so no intermediate resampling/quantization is
            // introduced before the Android tone profile.
            GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
            GLES31.glViewport(0, 0, displayWidth, displayHeight)
            GLES31.glUseProgram(postProgram)
            if (postUstMatrix >= 0) {
                GLES31.glUniformMatrix4fv(postUstMatrix, 1, false, transformMatrix, 0)
            }
            if (postSTex >= 0) GLES31.glUniform1i(postSTex, 0)
            if (postColorProfile >= 0) {
                GLES31.glUniform1i(postColorProfile, if (colorProfileEnabled && fullRange) 1 else 0)
            }
            GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
            GLES31.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
            drawQuad(postAPos, postATex)
        } else {
            // General path: OES -> 2D (FBO) -> post/scaler -> display.
            GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, fboId)
            GLES31.glViewport(0, 0, streamWidth, streamHeight)
            GLES31.glUseProgram(blitProgram)
            if (blitUstMatrix >= 0) {
                GLES31.glUniformMatrix4fv(blitUstMatrix, 1, false, transformMatrix, 0)
            }
            if (blitSTex >= 0) GLES31.glUniform1i(blitSTex, 0)
            GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
            GLES31.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
            drawQuad(blitAPos, blitATex)

            GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
            GLES31.glViewport(0, 0, displayWidth, displayHeight)
            GLES31.glUseProgram(postProgram)
            if (postSTex >= 0) GLES31.glUniform1i(postSTex, 0)
            if (postSharpness >= 0) GLES31.glUniform1f(postSharpness, sharpness)
            if (postColorProfile >= 0) {
                GLES31.glUniform1i(postColorProfile, if (colorProfileEnabled && fullRange) 1 else 0)
            }
            GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
            GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, fboTextureId)
            drawQuad(postAPos, postATex)
        }

        if (gpuTimerSupported) {
            GLES30.glEndQuery(GL_TIME_ELAPSED_EXT)
            gpuQueryPending = true
        }

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, cpuStart)
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)

        // ===== timing bookkeeping =====
        val cpuNs = System.nanoTime() - cpuStart
        cpuRing[cpuRingIdx] = cpuNs
        cpuRingIdx = (cpuRingIdx + 1) % cpuRing.size
        if (cpuRingCount < cpuRing.size) cpuRingCount++
        statBacklogSum += backlog
        statFrameCount++
        if (statFrameCount >= STAT_WINDOW) {
            val now = System.nanoTime()
            val fps = STAT_WINDOW * 1e9 / (now - statWindowStart)
            val sorted = cpuRing.copyOfRange(0, cpuRingCount).sorted()
            val avg = sorted.average() / 1_000_000.0
            val p95 = sorted[minOf(cpuRingCount - 1, (cpuRingCount * 0.95).toInt())] / 1_000_000.0
            val gpu = if (lastGpuMs.isNaN()) -1.0 else lastGpuMs
            val avgBacklog = statBacklogSum / STAT_WINDOW
            onStats?.invoke(Stats(mode, avg, p95, gpu, avgBacklog, fps))
            statFrameCount = 0
            statBacklogSum = 0
            statWindowStart = now
            lastGpuMs = Double.NaN
        }
    }

    private fun drawQuad(
        posHandle: Int,
        texHandle: Int,
    ) {
        if (posHandle >= 0) {
            GLES31.glEnableVertexAttribArray(posHandle)
            vertexBuffer.position(0)
            GLES31.glVertexAttribPointer(posHandle, 2, GLES31.GL_FLOAT, false, 16, vertexBuffer)
        }
        if (texHandle >= 0) {
            GLES31.glEnableVertexAttribArray(texHandle)
            vertexBuffer.position(2)
            GLES31.glVertexAttribPointer(texHandle, 2, GLES31.GL_FLOAT, false, 16, vertexBuffer)
        }
        GLES31.glDrawArrays(GLES31.GL_TRIANGLE_STRIP, 0, 4)
        if (posHandle >= 0) GLES31.glDisableVertexAttribArray(posHandle)
        if (texHandle >= 0) GLES31.glDisableVertexAttribArray(texHandle)
    }

    // ===================== SHADER MANAGEMENT =====================

    private fun compileTimeDefines(): String =
        "\n#define SRC_W " + streamWidth + ".0\n" +
            "#define SRC_H " + streamHeight + ".0\n" +
            "#define INV_SRC_W " + 1.0f / streamWidth + "\n" +
            "#define INV_SRC_H " + 1.0f / streamHeight + "\n"

    private fun applyPendingPostParams() {
        pendingMode?.let { mode = it }
        pendingSharpness?.let { sharpness = it }
        pendingEdgeThreshold?.let { edgeThreshold = it }
        pendingMode = null
        pendingSharpness = null
        pendingEdgeThreshold = null
        programDirty = false
        compilePostProgram()
    }

    private fun compilePostProgram() {
        if (postProgram != 0) {
            GLES31.glDeleteProgram(postProgram)
            postProgram = 0
        }

        val defines = compileTimeDefines()
        val normalVertexSource = POST_VERTEX_SHADER_PREFIX + defines + POST_VERTEX_SHADER_BODY
        // QTI reports the 2800x1752 panel stream as a block-aligned 2800x1760
        // texture, while SurfaceTexture carries the effective crop. Treat that
        // bounded 8-pixel height padding as exact-size so the decoded image
        // still avoids an intermediate FBO copy.
        val exactBridge =
            mode == Mode.BRIDGE_ONLY &&
                displayWidth == streamWidth &&
                abs(displayHeight - streamHeight) <= NEAR_NATIVE_DIMENSION_TOLERANCE
        postUsesExternalTexture = exactBridge
        val vertexSource = if (exactBridge) BLIT_VERTEX_SHADER else normalVertexSource
        val fragmentSource = if (exactBridge) {
            DIRECT_BRIDGE_POST_FRAGMENT_SHADER
        } else {
            when (mode) {
                Mode.BRIDGE_ONLY -> {
                    val needsUpscale = displayWidth > streamWidth || displayHeight > streamHeight
                    if (needsUpscale) {
                        BICUBIC_BRIDGE_POST_FRAGMENT_SHADER.replaceFirst(
                            Regex("#version 310 es"),
                            "#version 310 es$defines",
                        )
                    } else {
                        BRIDGE_POST_FRAGMENT_SHADER
                    }
                }
                Mode.CAS -> CAS_POST_FRAGMENT_SHADER.replaceFirst(Regex("#version 310 es"), "#version 310 es$defines")
                Mode.SGSR1 -> {
                    val raw = loadAsset("sgsr1_shader_mobile_edge_direction.frag")
                    if (raw == null) {
                        DiagLog.log("SGSR", "SGSR1 asset missing — using bridge shader")
                        BRIDGE_POST_FRAGMENT_SHADER
                    } else {
                        // Inject stream size right after #version for compile-time constant folding.
                        // The Qualcomm reference shader uses EdgeSharpness 2.0. The shared UI
                        // control is normalized to 0..1 for CAS, so map it to the SGSR1
                        // algorithm's full 0..2 range instead of silently limiting SGSR1 to
                        // half strength.
                        val effectiveSharpness = sharpness * SGSR1_EDGE_SHARPNESS_MAX
                        raw.replaceFirst(
                            Regex("#version 310 es"),
                            "#version 310 es$defines${AndroidColorProfile.GLSL_FUNCTION}\n",
                        )
                            .replaceFirst(Regex("#define EdgeThreshold .*"), "#define EdgeThreshold $edgeThreshold")
                            .replaceFirst(Regex("#define EdgeSharpness .*"), "#define EdgeSharpness $effectiveSharpness")
                    }
                }
            }
        }

        postProgram = createProgram(vertexSource, fragmentSource)
        if (postProgram == 0) {
            DiagLog.log("SGSR", "post program failed — falling back to bridge shader")
            postUsesExternalTexture = false
            postProgram = createProgram(normalVertexSource, BRIDGE_POST_FRAGMENT_SHADER)
        }
        postAPos = GLES31.glGetAttribLocation(postProgram, "aPosition")
        postATex = GLES31.glGetAttribLocation(postProgram, "aTexCoord")
        postUstMatrix = GLES31.glGetUniformLocation(postProgram, "uSTMatrix")
        postSTex = GLES31.glGetUniformLocation(postProgram, "ps0")
        if (postSTex < 0) postSTex = GLES31.glGetUniformLocation(postProgram, "sTexture")
        postSharpness = GLES31.glGetUniformLocation(postProgram, "uSharpness")
        postColorProfile = GLES31.glGetUniformLocation(postProgram, "uAndroidColorProfile")
        val effectiveSharpness =
            if (mode == Mode.SGSR1) sharpness * SGSR1_EDGE_SHARPNESS_MAX else sharpness
        DiagLog.log(
            "SGSR",
            "post program compiled: mode=$mode sharpness=$sharpness " +
                "effectiveSharpness=$effectiveSharpness edgeThreshold=$edgeThreshold " +
                "androidColorProfile=${colorProfileEnabled && fullRange} " +
                "sourceRange=${if (fullRange) "full" else "limited"} " +
                "upscale=${mode == Mode.BRIDGE_ONLY && (displayWidth > streamWidth || displayHeight > streamHeight)} " +
                "externalTexture=$postUsesExternalTexture " +
                "output=${displayWidth}x$displayHeight",
        )
    }

    private fun loadAsset(fileName: String): String? {
        val sb = StringBuilder()
        try {
            context.assets.open(fileName).use { input ->
                BufferedReader(InputStreamReader(input)).use { reader ->
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        sb.append(line).append('\n')
                    }
                }
            }
        } catch (e: Exception) {
            DiagLog.log("SGSR", "loadAsset($fileName) failed: ${e.message}")
            return null
        }
        return sb.toString()
    }

    private fun createProgram(
        vertexSource: String,
        fragmentSource: String,
    ): Int {
        val vs = loadShader(GLES31.GL_VERTEX_SHADER, vertexSource)
        if (vs == 0) return 0
        val fs = loadShader(GLES31.GL_FRAGMENT_SHADER, fragmentSource)
        if (fs == 0) {
            GLES31.glDeleteShader(vs)
            return 0
        }
        val program = GLES31.glCreateProgram()
        GLES31.glAttachShader(program, vs)
        GLES31.glAttachShader(program, fs)
        GLES31.glLinkProgram(program)
        GLES31.glDeleteShader(vs)
        GLES31.glDeleteShader(fs)
        val status = IntArray(1)
        GLES31.glGetProgramiv(program, GLES31.GL_LINK_STATUS, status, 0)
        if (status[0] != GLES31.GL_TRUE) {
            DiagLog.log("SGSR", "link failed: ${GLES31.glGetProgramInfoLog(program)}")
            GLES31.glDeleteProgram(program)
            return 0
        }
        return program
    }

    private fun loadShader(
        type: Int,
        source: String,
    ): Int {
        val shader = GLES31.glCreateShader(type)
        GLES31.glShaderSource(shader, source)
        GLES31.glCompileShader(shader)
        val compiled = IntArray(1)
        GLES31.glGetShaderiv(shader, GLES31.GL_COMPILE_STATUS, compiled, 0)
        if (compiled[0] == 0) {
            DiagLog.log("SGSR", "shader compile failed: ${GLES31.glGetShaderInfoLog(shader)}")
            GLES31.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    private fun teardownGl() {
        if (postProgram != 0) {
            GLES31.glDeleteProgram(postProgram)
            postProgram = 0
        }
        if (blitProgram != 0) {
            GLES31.glDeleteProgram(blitProgram)
            blitProgram = 0
        }
        if (fboId != 0) {
            GLES31.glDeleteFramebuffers(1, intArrayOf(fboId), 0)
            fboId = 0
        }
        if (oesTextureId != 0 || fboTextureId != 0) {
            GLES31.glDeleteTextures(2, intArrayOf(oesTextureId, fboTextureId), 0)
            oesTextureId = 0
            fboTextureId = 0
        }
        if (gpuQuery != 0) {
            GLES30.glDeleteQueries(1, intArrayOf(gpuQuery), 0)
            gpuQuery = 0
        }
        surfaceTexture?.setOnFrameAvailableListener(null)
        surfaceTexture?.release()
        surfaceTexture = null
        decoderSurface?.release()
        decoderSurface = null
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, eglSurface)
                eglSurface = EGL14.EGL_NO_SURFACE
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(eglDisplay, eglContext)
                eglContext = EGL14.EGL_NO_CONTEXT
            }
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(eglDisplay)
            eglDisplay = EGL14.EGL_NO_DISPLAY
        }
        DiagLog.log("SGSR", "teardown complete")
    }

    companion object {
        private const val TAG = "SgsrRenderer"
        private const val STAT_WINDOW = 60
        private const val MAX_DRAIN = 8
        private const val SGSR1_EDGE_SHARPNESS_MAX = 2.0f
        private const val NEAR_NATIVE_DIMENSION_TOLERANCE = 8

        // EXT_disjoint_timer_query constants (reuse core ES3 query entry points)
        private const val GL_TIME_ELAPSED_EXT = 0x88BF
        private const val GL_QUERY_RESULT_EXT = 0x8866
        private const val GL_QUERY_RESULT_AVAILABLE_EXT = 0x8867
    }
}
