package com.sidescreen.app

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.Dialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.graphics.drawable.ColorDrawable
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceHolder
import android.view.TextureView
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.constraintlayout.widget.ConstraintSet
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.google.android.material.slider.Slider
import com.google.android.material.switchmaterial.SwitchMaterial
import com.sidescreen.app.databinding.ActivityMainBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

private fun mainDiag(msg: String) = DiagLog.log("MA", msg)

// Debug A/B hook action: adb shell am broadcast -a dev.tabletbridge.app.VSR_CMD
//   --ez enabled true --es mode sgsr [--ef sharpness 0.8] [--ef edge_threshold 0.03]
//   --ez enabled true --es mode cfl [--ef cfl_strength 0.15] [--ez color_profile false]
private const val VSR_CMD_ACTION = "dev.tabletbridge.app.VSR_CMD"
private const val LAB_CMD_ACTION = "dev.tabletbridge.app.LAB_CMD"
private const val DEFAULT_USB_HOST = "127.0.0.1"
private const val DEFAULT_USB_PORT = 54321

class MainActivity : AppCompatActivity() {
    private val sessionController = SessionController()
    private lateinit var wirelessController: WirelessTabController
    private val pairedHostStorage by lazy { PairedHostStorage(this) }
    private val cameraPerm by lazy { CameraPermissionManager(this) }
    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: PreferencesManager
    private var videoDecoder: VideoDecoder? = null
    private var sgsrRenderer: SgsrRenderer? = null
    private var cflRenderer: CflRenderer? = null
    @Volatile private var streamClient: StreamClient? = null
    private var currentSurfaceHolder: SurfaceHolder? = null
    private var currentTextureSurface: Surface? = null
    private var decoderUsingTextureView = false
    private var displayWidth = 0 // 0 = no config received yet
    private var displayHeight = 0 // 0 = no config received yet
    private var displayRotation = 0 // 0, 90, 180, 270 degrees
    private var displayFlipHorizontal = false
    private var displayFlipVertical = false
    private var pingJob: kotlinx.coroutines.Job? = null
    private lateinit var brightnessOwnership: BrightnessOwnershipController
    private lateinit var presentationController: PresentationController
    private var pendingBrightnessGeneration: Long? = null
    private var pendingBrightness: Int? = null
    private var restartChecklistAfterDisconnect = true

    // All callbacks from an old StreamClient become inert as soon as a newer
    // connect starts. Without this generation fence, a sender restart can
    // leave several clients reconnecting at once and starve the decoder.
    /** Derived UI convenience; SessionController remains the only source. */
    private val hasActiveSession: Boolean
        get() = sessionController.hasTransport()

    // For dragging stats overlay
    private var isDraggingOverlay = false
    private var overlayDx = 0f
    private var overlayDy = 0f

    // Input prediction for low-latency gaming
    private val inputPredictor = InputPredictor()

    // Checklist status handler
    private val checklistHandler = Handler(Looper.getMainLooper())
    private var checklistRunnable: Runnable? = null
    // Auto-disconnect: if the app stays backgrounded past the configured
    // window (default 60 s; adb-tunable via
    //   adb shell settings put system sidescreen_auto_disconnect_secs <N>)
    // the session tears itself down. A killed process needs no timer — its
    // sockets die and the host's idle-sleep takes over.
    private var backgroundedAtMs = 0L
    private var autoDisconnectJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        DiagLog.init(applicationContext)
        prefs = PreferencesManager(this)
        brightnessOwnership = BrightnessOwnershipController(this) { window }
        presentationController = PresentationController(this, brightnessOwnership)
        sessionController.onStateChanged = { state ->
            runOnUiThread { renderSessionState(state) }
        }

        // Allow rotation based on device sensor when not connected
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR

        // Enable edge-to-edge display (draw behind system bars and cutout)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        setupSurface()
        setupUI()
        setupDraggableOverlay()
        setupSettingsButton()
        restoreOverlayPosition()
        restoreSettingsButtonPosition()
        startChecklistUpdates()
        setupModeToggle()
        setupWirelessController()
        setupVsrCommandReceiver()
        setupLabCommandReceiver()
        renderSessionState(sessionController.state)

        // USB screen sharing is deliberately manual. ADB/USB becoming
        // available must never open a video or control socket on its own.
        log("Manual connection mode enabled — tap Connect to start")
    }

    private fun setupModeToggle() {
        // Restore previous mode and reflect in toggle.
        val saved = prefs.connectionMode
        binding.modeToggleGroup.check(if (saved == ConnectionMode.WIRELESS) R.id.modeWireless else R.id.modeUSB)
        applyModeVisibility(saved)

        binding.modeToggleGroup.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val mode = if (checkedId == R.id.modeWireless) ConnectionMode.WIRELESS else ConnectionMode.USB
            prefs.connectionMode = mode
            applyModeVisibility(mode)
            if (mode == ConnectionMode.WIRELESS) {
                wirelessController.show()
            }
        }
    }

    private fun applyModeVisibility(mode: ConnectionMode) {
        binding.usbModeContent.visibility = if (mode == ConnectionMode.USB) View.VISIBLE else View.GONE
        binding.wirelessModeContent.visibility = if (mode == ConnectionMode.WIRELESS) View.VISIBLE else View.GONE
        // Checklist updates are local-only while idle. They must not probe the
        // Mac listener because the host accepts one screen-sharing client and
        // a background probe can look like an unwanted reconnect.
        if (mode == ConnectionMode.WIRELESS || hasActiveSession) {
            stopChecklistUpdates()
        } else {
            startChecklistUpdates()
        }
    }

    private fun setupWirelessController() {
        wirelessController =
            WirelessTabController(
                activity = this,
                views =
                    WirelessTabController.Views(
                        connecting = binding.wirelessConnecting,
                        firstTime = binding.wirelessFirstTime,
                        connected = binding.wirelessConnected,
                        pairedIdle = binding.wirelessPairedIdle,
                        repair = binding.wirelessTokenMismatch,
                        permDenied = binding.wirelessPermDenied,
                        scanButton = binding.wirelessScanButton,
                        rescanButton = binding.wirelessRescanButton,
                        disconnectButton = binding.wirelessDisconnectButton,
                        forgetButton = binding.wirelessForgetButton,
                        reconnectButton = binding.wirelessReconnectButton,
                        idleForgetButton = binding.wirelessIdleForgetButton,
                        openSettingsButton = binding.wirelessOpenSettingsButton,
                        connectedMacName = binding.connectedMacName,
                        connectedMacIp = binding.connectedMacIp,
                        connectingLabel = binding.connectingLabel,
                        connectingSubtitle = binding.connectingSubtitle,
                        idleMacName = binding.idleMacName,
                        idleMacIp = binding.idleMacIp,
                        repairTitle = binding.repairTitle,
                        repairMessage = binding.repairMessage,
                    ),
                storage = pairedHostStorage,
                cameraPerm = cameraPerm,
                onConnectRequested = { host, port, token, deviceName, _ ->
                    connectWireless(host, port, token, deviceName)
                },
            )
        wirelessController.bind()
        binding.wirelessDisconnectButton.setOnClickListener { disconnect() }
        if (prefs.connectionMode == ConnectionMode.WIRELESS) {
            wirelessController.show()
        }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: android.content.Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == WirelessTabController.REQ_SCAN && resultCode == RESULT_OK) {
            val url = data?.getStringExtra(QRScannerActivity.EXTRA_URL) ?: return
            wirelessController.onScanResult(url)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == WirelessTabController.REQ_CAMERA) {
            val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
            wirelessController.onCameraPermissionResult(granted)
        }
    }

    /** Keep the panel awake only while an active stream is visible. */
    private fun updateScreenPowerState(streamingVisible: Boolean) {
        if (streamingVisible) {
            presentationController.restoreScreenAwakeIfOwned()
        } else {
            presentationController.suspendScreenAwake()
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupSurface() {
        binding.surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    mainDiag("surfaceCreated")
                    log("Surface created")
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("surfaceChanged: ${width}x$height")
                    log("Surface changed: ${width}x$height")
                    currentSurfaceHolder = holder
                    initializeDecoderForCurrentSurface(sessionController.currentGeneration)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    mainDiag("surfaceDestroyed")
                    log("Surface destroyed")
                    if (!decoderUsingTextureView) {
                        videoDecoder?.release()
                        videoDecoder = null
                        sgsrRenderer?.release()
                        sgsrRenderer = null
                    }
                    currentSurfaceHolder = null
                }
            },
        )

        binding.textureView.surfaceTextureListener =
            object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("textureAvailable: ${width}x$height")
                    currentTextureSurface = Surface(surface)
                    initializeDecoderForCurrentSurface(sessionController.currentGeneration)
                }

                override fun onSurfaceTextureSizeChanged(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("textureSizeChanged: ${width}x$height")
                    applyTextureTransform()
                }

                override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                    mainDiag("textureDestroyed")
                    if (decoderUsingTextureView) {
                        videoDecoder?.release()
                        videoDecoder = null
                        sgsrRenderer?.release()
                        sgsrRenderer = null
                    }
                    currentTextureSurface?.release()
                    currentTextureSurface = null
                    return true
                }

                override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
            }

        if (binding.textureView.isAvailable && currentTextureSurface == null) {
            binding.textureView.surfaceTexture?.let { currentTextureSurface = Surface(it) }
        }

        binding.surfaceView.setOnTouchListener { view, event ->
            if (!sessionController.shouldForwardTouch()) {
                false
            } else {
                handleTouch(view, event)
                true
            }
        }
        binding.textureView.setOnTouchListener { view, event ->
            if (!sessionController.shouldForwardTouch()) {
                false
            } else {
                handleTouch(view, event)
                true
            }
        }
    }

    private fun setupUI() {
        binding.connectButton.setOnClickListener {
            var host =
                binding.hostInput.text
                    .toString()
                    .ifEmpty { DEFAULT_USB_HOST }
            val port =
                binding.portInput.text
                    .toString()
                    .toIntOrNull() ?: DEFAULT_USB_PORT

            // Convert localhost to 127.0.0.1 for better Android compatibility
            if (host.equals("localhost", ignoreCase = true)) {
                host = "127.0.0.1"
            }

            // Validate input
            if (host.isBlank()) {
                showError("Please enter a host address")
                return@setOnClickListener
            }

            if (sessionController.state is SessionController.State.Connecting) {
                return@setOnClickListener
            }
            binding.connectButton.isEnabled = false
            setStatusIndicator(R.drawable.status_indicator_amber)
            updateStatus("Connecting…")
            connect(host, port)
        }

        binding.disconnectButton.setOnClickListener {
            disconnect()
        }

        // Advanced settings toggle
        var advancedVisible = false
        binding.showAdvanced.setOnClickListener {
            advancedVisible = !advancedVisible
            binding.advancedSettings.visibility = if (advancedVisible) View.VISIBLE else View.GONE
            binding.showAdvanced.text = if (advancedVisible) "Hide Advanced Settings" else "Advanced Settings"
        }

        // Initial status
        updateStatus("Ready — tap Connect to start")
        setStatusIndicator(R.drawable.status_indicator_amber)
    }

    private fun showError(message: String) {
        runOnUiThread {
            android.app.AlertDialog
                .Builder(this)
                .setTitle("Connection Error")
                .setMessage(message)
                .setPositiveButton("OK", null)
                .show()
        }
    }

    private fun updateStatus(status: String) {
        runOnUiThread {
            binding.statusText.text = status
        }
    }

    private fun setStatusIndicator(drawableRes: Int) {
        binding.statusIndicator.setBackgroundResource(drawableRes)
    }

    @SuppressLint("ClickableViewAccessibility", "InflateParams")
    private fun setupDraggableOverlay() {
        binding.statusBar.setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    isDraggingOverlay = true
                    overlayDx = view.x - event.rawX
                    overlayDy = view.y - event.rawY
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (isDraggingOverlay) {
                        // Calculate new position
                        var newX = event.rawX + overlayDx
                        var newY = event.rawY + overlayDy

                        // Get screen bounds
                        val parent = view.parent as View
                        val maxX = parent.width - view.width.toFloat()
                        val maxY = parent.height - view.height.toFloat()

                        // Constrain to screen bounds
                        newX = newX.coerceIn(0f, maxX)
                        newY = newY.coerceIn(0f, maxY)

                        view
                            .animate()
                            .x(newX)
                            .y(newY)
                            .setDuration(0)
                            .start()
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (isDraggingOverlay) {
                        // Save position
                        prefs.overlayX = view.x
                        prefs.overlayY = view.y
                        isDraggingOverlay = false
                    }
                    true
                }

                else -> {
                    false
                }
            }
        }
    }

    private fun restoreOverlayPosition() {
        val x = prefs.overlayX
        val y = prefs.overlayY

        if (x >= 0 && y >= 0) {
            binding.statusBar.post {
                binding.statusBar.x = x
                binding.statusBar.y = y
            }
        }

        // Apply opacity to both overlay and settings button
        val opacity = prefs.overlayOpacity
        updateOverlayOpacity(opacity)
        updateSettingsButtonOpacity(opacity)

        // Apply visibility
        updateOverlayVisibility(prefs.showStatsOverlay)
    }

    private fun updateOverlayOpacity(opacity: Float) {
        binding.statusBar.alpha = opacity
    }

    private fun updateOverlayVisibility(show: Boolean) {
        if (hasActiveSession && show) {
            binding.statusBar.visibility = View.VISIBLE
            // Restore position when showing
            val x = prefs.overlayX
            val y = prefs.overlayY
            if (x >= 0 && y >= 0) {
                binding.statusBar.post {
                    binding.statusBar.x = x
                    binding.statusBar.y = y
                }
            }
        } else {
            binding.statusBar.visibility = View.GONE
        }
    }

    @SuppressLint("InflateParams", "SetTextI18n")
    private fun showSettingsDialog() {
        val dialog = Dialog(this)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setContentView(R.layout.dialog_settings)
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        val view = dialog.findViewById<View>(android.R.id.content)
        val showStatsSwitch = view.findViewById<SwitchMaterial>(R.id.showStatsSwitch)
        val hideSettingsSwitch = view.findViewById<SwitchMaterial>(R.id.hideSettingsSwitch)
        val opacitySlider = view.findViewById<Slider>(R.id.opacitySlider)
        val opacityValue = view.findViewById<TextView>(R.id.opacityValue)
        val resetButton = view.findViewById<View>(R.id.resetPositionButton)
        val resetSettingsBtn = view.findViewById<View>(R.id.resetSettingsButton)
        val disconnectButton = view.findViewById<View>(R.id.disconnectSettingsButton)
        val closeButton = view.findViewById<View>(R.id.closeButton)

        // Only show Disconnect when actually streaming. Otherwise the button is
        // a no-op and confuses users into clicking it twice.
        disconnectButton.visibility = if (sessionController.isStreaming()) View.VISIBLE else View.GONE

        // Position buttons (8 directions)
        val cornerTopLeft = view.findViewById<MaterialButton>(R.id.cornerTopLeft)
        val cornerTopRight = view.findViewById<MaterialButton>(R.id.cornerTopRight)
        val cornerBottomLeft = view.findViewById<MaterialButton>(R.id.cornerBottomLeft)
        val cornerBottomRight = view.findViewById<MaterialButton>(R.id.cornerBottomRight)
        val positionTopCenter = view.findViewById<MaterialButton>(R.id.positionTopCenter)
        val positionBottomCenter = view.findViewById<MaterialButton>(R.id.positionBottomCenter)
        val positionCenterLeft = view.findViewById<MaterialButton>(R.id.positionCenterLeft)
        val positionCenterRight = view.findViewById<MaterialButton>(R.id.positionCenterRight)

        // Load current settings
        showStatsSwitch.isChecked = prefs.showStatsOverlay
        hideSettingsSwitch.isChecked = prefs.hideSettingsButton
        opacitySlider.value = prefs.overlayOpacity
        opacityValue.text = "${(prefs.overlayOpacity * 100).toInt()}%"

        // Highlight current position selection (8 positions)
        // 0=BottomRight, 1=BottomLeft, 2=TopRight, 3=TopLeft
        // 4=TopCenter, 5=BottomCenter, 6=CenterLeft, 7=CenterRight
        fun updatePositionSelection(selectedPosition: Int) {
            val buttons =
                listOf(
                    cornerBottomRight,
                    cornerBottomLeft,
                    cornerTopRight,
                    cornerTopLeft,
                    positionTopCenter,
                    positionBottomCenter,
                    positionCenterLeft,
                    positionCenterRight,
                )
            buttons.forEachIndexed { index, button ->
                if (index == selectedPosition) {
                    button.backgroundTintList =
                        android.content.res.ColorStateList
                            .valueOf(0x334CAF50)
                } else {
                    button.backgroundTintList = null
                }
            }
        }
        updatePositionSelection(prefs.settingsButtonCorner)

        // Setup listeners
        showStatsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.showStatsOverlay = isChecked
            updateOverlayVisibility(isChecked)
        }

        hideSettingsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.hideSettingsButton = isChecked
            if (hasActiveSession) {
                applySettingsButtonVisibility()
            }
            if (isChecked) {
                android.widget.Toast
                    .makeText(
                        this,
                        "Settings icon hidden — use the back gesture to reveal it",
                        android.widget.Toast.LENGTH_LONG,
                    ).show()
            }
        }

        // ---- Video Super Resolution ----
        val vsrSwitch = view.findViewById<SwitchMaterial>(R.id.vsrSwitch)
        val vsrModeBridge = view.findViewById<MaterialButton>(R.id.vsrModeBridge)
        val vsrModeSgsr = view.findViewById<MaterialButton>(R.id.vsrModeSgsr)
        val vsrModeCas = view.findViewById<MaterialButton>(R.id.vsrModeCas)
        val vsrStatus = view.findViewById<TextView>(R.id.vsrStatus)

        vsrSwitch.isChecked = prefs.vsrEnabled
        vsrSwitch.isEnabled = supportsGles31()
        if (!supportsGles31()) {
            vsrStatus.text = "Requires OpenGL ES 3.1"
        }

        fun updateVsrModeSelection() {
            val current = SgsrRenderer.Mode.from(prefs.vsrMode)
            val map =
                mapOf(
                    vsrModeBridge to SgsrRenderer.Mode.BRIDGE_ONLY,
                    vsrModeSgsr to SgsrRenderer.Mode.SGSR1,
                    vsrModeCas to SgsrRenderer.Mode.CAS,
                )
            map.forEach { (btn, m) ->
                btn.backgroundTintList =
                    if (m == current) android.content.res.ColorStateList.valueOf(0x334CAF50) else null
            }
        }
        updateVsrModeSelection()

        vsrSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.vsrEnabled = isChecked
            restartVideoPath()
        }

        val androidColorProfileSwitch = view.findViewById<SwitchMaterial>(R.id.androidColorProfileSwitch)
        val androidColorProfileStatus = view.findViewById<TextView>(R.id.androidColorProfileStatus)
        val colorProfileSupported = supportsGles31()
        androidColorProfileSwitch.isChecked = prefs.androidColorProfileEnabled
        androidColorProfileSwitch.isEnabled = colorProfileSupported
        androidColorProfileStatus.text =
            if (colorProfileSupported) AndroidColorProfile.NAME else "Requires OpenGL ES 3.1 GPU path"
        androidColorProfileSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.androidColorProfileEnabled = isChecked
            val needsUsbDirectPathRebuild =
                hasActiveSession &&
                    prefs.connectionMode == ConnectionMode.USB &&
                    !prefs.vsrEnabled &&
                    supportsGles31() &&
                    !shouldUseTextureView()
            if (needsUsbDirectPathRebuild) {
                // The direct MediaCodec -> Surface path has no shader stage.
                // Rebuild only that local path so the profile can be added or
                // removed without disconnecting USB or restarting the stream.
                restartVideoPath()
            } else {
                sgsrRenderer?.setAndroidColorProfileEnabled(isChecked)
                cflRenderer?.setAndroidColorProfileEnabled(isChecked)
            }
        }

        vsrModeBridge.setOnClickListener {
            prefs.vsrMode = SgsrRenderer.Mode.BRIDGE_ONLY.name
            updateVsrModeSelection()
            restartVideoPath()
        }
        vsrModeSgsr.setOnClickListener {
            prefs.vsrMode = SgsrRenderer.Mode.SGSR1.name
            updateVsrModeSelection()
            restartVideoPath()
        }
        vsrModeCas.setOnClickListener {
            prefs.vsrMode = SgsrRenderer.Mode.CAS.name
            updateVsrModeSelection()
            restartVideoPath()
        }

        // Live VSR param sliders — no restart needed (renderer recompiles shader on the fly)
        val vsrSharpnessSlider = view.findViewById<Slider>(R.id.vsrSharpnessSlider)
        val vsrSharpnessValue = view.findViewById<TextView>(R.id.vsrSharpnessValue)
        val vsrEdgeSlider = view.findViewById<Slider>(R.id.vsrEdgeSlider)
        val vsrEdgeValue = view.findViewById<TextView>(R.id.vsrEdgeValue)

        vsrSharpnessSlider.value = prefs.vsrSharpness
        vsrSharpnessValue.text = "%.2f".format(prefs.vsrSharpness)
        vsrEdgeSlider.value = prefs.vsrEdgeThreshold
        vsrEdgeValue.text = "%.3f".format(prefs.vsrEdgeThreshold)

        vsrSharpnessSlider.addOnChangeListener { _, value, _ ->
            prefs.vsrSharpness = value
            vsrSharpnessValue.text = "%.2f".format(value)
            sgsrRenderer?.setSharpness(value)
        }
        vsrEdgeSlider.addOnChangeListener { _, value, _ ->
            prefs.vsrEdgeThreshold = value
            vsrEdgeValue.text = "%.3f".format(value)
            sgsrRenderer?.setEdgeThreshold(value)
        }

        opacitySlider.addOnChangeListener { _, value, _ ->
            prefs.overlayOpacity = value
            updateOverlayOpacity(value)
            updateSettingsButtonOpacity(value)
            opacityValue.text = "${(value * 100).toInt()}%"
        }

        resetButton.setOnClickListener {
            prefs.overlayX = -1f
            prefs.overlayY = -1f
            // Use displayMetrics for reliable positioning
            val dm = resources.displayMetrics
            binding.statusBar
                .animate()
                .x(dm.widthPixels - binding.statusBar.width - 48f)
                .y(48f)
                .setDuration(300)
                .start()
        }

        // Position button listeners (8 directions)
        cornerBottomRight.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        cornerBottomLeft.setOnClickListener {
            prefs.settingsButtonCorner = 1
            updatePositionSelection(1)
            updateSettingsButtonPosition(1)
        }

        cornerTopRight.setOnClickListener {
            prefs.settingsButtonCorner = 2
            updatePositionSelection(2)
            updateSettingsButtonPosition(2)
        }

        cornerTopLeft.setOnClickListener {
            prefs.settingsButtonCorner = 3
            updatePositionSelection(3)
            updateSettingsButtonPosition(3)
        }

        positionTopCenter.setOnClickListener {
            prefs.settingsButtonCorner = 4
            updatePositionSelection(4)
            updateSettingsButtonPosition(4)
        }

        positionBottomCenter.setOnClickListener {
            prefs.settingsButtonCorner = 5
            updatePositionSelection(5)
            updateSettingsButtonPosition(5)
        }

        positionCenterLeft.setOnClickListener {
            prefs.settingsButtonCorner = 6
            updatePositionSelection(6)
            updateSettingsButtonPosition(6)
        }

        positionCenterRight.setOnClickListener {
            prefs.settingsButtonCorner = 7
            updatePositionSelection(7)
            updateSettingsButtonPosition(7)
        }

        resetSettingsBtn.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        disconnectButton.setOnClickListener {
            dialog.dismiss()
            disconnect()
        }

        closeButton.setOnClickListener {
            dialog.dismiss()
        }

        dialog.show()

        // Cap dialog height to 85% of screen so content scrolls on smaller screens / landscape
        dialog.window?.let { win ->
            val maxH = (resources.displayMetrics.heightPixels * 0.85).toInt()
            win.setLayout(WindowManager.LayoutParams.MATCH_PARENT, maxH)
        }
    }

    private fun updateSettingsButtonOpacity(opacity: Float) {
        binding.settingsButton.alpha = opacity
    }

    private fun setupSettingsButton() {
        // Simple click to show settings dialog
        // Position can be changed via corner buttons in settings
        binding.settingsButton.setOnClickListener {
            showSettingsDialog()
        }

        // Escape hatch for the hidden icon: the back gesture briefly reveals it
        // instead of leaving the app. Back is not forwarded to the Mac, so this
        // cannot conflict with streamed touch input.
        onBackPressedDispatcher.addCallback(
            this,
            object : androidx.activity.OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (sessionController.isStreaming() && prefs.hideSettingsButton &&
                        binding.settingsButton.visibility != View.VISIBLE
                    ) {
                        revealSettingsButtonTemporarily()
                    } else {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                        isEnabled = true
                    }
                }
            },
        )
    }

    /** Streaming-time visibility of the settings icon, honoring the hide preference. */
    private fun applySettingsButtonVisibility() {
        binding.settingsButton.visibility =
            if (prefs.hideSettingsButton) View.GONE else View.VISIBLE
    }

    private val revealHandler = Handler(Looper.getMainLooper())
    private val hideSettingsButtonRunnable =
        Runnable {
            if (sessionController.isStreaming() && prefs.hideSettingsButton) {
                binding.settingsButton.visibility = View.GONE
            }
        }

    private fun revealSettingsButtonTemporarily() {
        binding.settingsButton.visibility = View.VISIBLE
        revealHandler.removeCallbacks(hideSettingsButtonRunnable)
        revealHandler.postDelayed(hideSettingsButtonRunnable, 5_000L)
    }

    private fun restoreSettingsButtonPosition() {
        updateSettingsButtonPosition(prefs.settingsButtonCorner)
    }

    /**
     * Use ConstraintSet to position settings button - most reliable method
     * Works correctly with orientation changes
     * Supports 8 positions: 4 corners + 4 edges
     */
    private fun updateSettingsButtonPosition(position: Int) {
        val constraintLayout = binding.root
        val constraintSet = ConstraintSet()
        constraintSet.clone(constraintLayout)

        val buttonId = binding.settingsButton.id
        val marginDp = (24 * resources.displayMetrics.density).toInt()

        // Clear all constraints first
        constraintSet.clear(buttonId, ConstraintSet.TOP)
        constraintSet.clear(buttonId, ConstraintSet.BOTTOM)
        constraintSet.clear(buttonId, ConstraintSet.START)
        constraintSet.clear(buttonId, ConstraintSet.END)

        when (position) {
            0 -> { // Bottom Right (default)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            1 -> { // Bottom Left
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            2 -> { // Top Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            3 -> { // Top Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            4 -> { // Top Center
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            5 -> { // Bottom Center
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            6 -> { // Center Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            7 -> { // Center Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            else -> { // Default to bottom right
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }
        }

        // Reset any absolute positioning that might have been set
        binding.settingsButton.translationX = 0f
        binding.settingsButton.translationY = 0f

        constraintSet.applyTo(constraintLayout)
    }

    /**
     * Display config from a new Mac always arrives AFTER codecSelected, so a
     * missing negotiation at this point proves the Mac app predates H.264
     * support — surface that instead of a silent black screen.
     */
    private fun warnIfAvcOnlyWithoutNegotiation(client: StreamClient) {
        if (!CodecCapabilities.hasHevcDecoder && client.codecNegotiated != true) {
            mainDiag("AVC-only device but Mac did not negotiate codec — Mac app too old")
            runOnUiThread {
                updateStatus("This device has no HEVC decoder. Update the Tablet Bridge Mac app to enable H.264 support.")
            }
        }
    }

    /**
     * Recreate the decoder when the negotiated stream codec doesn't match the
     * decoder's mime. Display config and codecSelected can arrive in either
     * order on reconnect; without this, a decoder created with the default
     * HEVC mime keeps consuming the H.264 stream and never outputs a frame —
     * a permanent black screen on AVC-only devices (e.g. Unisoc tablets).
     */
    private fun onStreamCodecSelected(generation: Long, isHevc: Boolean) {
        val expectedMime =
            if (isHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        runOnUiThread {
            if (!sessionController.isCurrent(generation)) return@runOnUiThread
            val dec = videoDecoder
            when {
                dec == null -> {
                    mainDiag("Codec selected ($expectedMime) — initializing deferred decoder")
                    initializeDecoderForCurrentSurface(generation, streamClient)
                }
                dec.mime != expectedMime -> {
                    mainDiag("Stream codec is $expectedMime but decoder is ${dec.mime} — recreating")
                    dec.release()
                    videoDecoder = null
                    initializeDecoderForCurrentSurface(generation, streamClient)
                }
            }
        }
    }

    private fun shouldUseTextureView(): Boolean = displayFlipHorizontal || displayFlipVertical

    private fun supportsGles31(): Boolean {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.deviceConfigurationInfo.reqGlEsVersion >= 0x30001
    }

    private fun isUsbColorBridgePathActive(): Boolean =
        prefs.connectionMode == ConnectionMode.USB &&
            prefs.androidColorProfileEnabled &&
            supportsGles31() &&
            !shouldUseTextureView() &&
            !prefs.vsrEnabled

    /** Recreate the video path (decoder + optional VSR renderer) with current prefs. */
    private fun restartVideoPath() {
        if (!hasActiveSession) return
        videoDecoder?.release()
        videoDecoder = null
        sgsrRenderer?.release()
        sgsrRenderer = null
        cflRenderer?.release()
        cflRenderer = null
        applyDirectPixelMapping(displayWidth, displayHeight)
        initializeDecoderForCurrentSurface(sessionController.currentGeneration, streamClient)
    }

    /**
     * Preserve a one-stream-pixel-to-one-panel-pixel mapping for near-native
     * direct streams. Stretching a 98-99% stream across the whole panel makes
     * SurfaceFlinger resample every pixel and visibly softens text. Centering
     * the surface at its encoded size leaves only a tiny black border while
     * keeping the decoded image pixel exact. Lower-resolution streams and VSR
     * modes continue filling the panel as before.
     */
    private fun applyDirectPixelMapping(
        streamWidth: Int,
        streamHeight: Int,
    ) {
        binding.surfaceView.post {
            val panelWidth = binding.root.width
            val panelHeight = binding.root.height
            val usbColorBridgeOn = isUsbColorBridgePathActive()
            val nearNative =
                !usbColorBridgeOn &&
                !prefs.vsrEnabled &&
                    !shouldUseTextureView() &&
                    streamWidth in 1..panelWidth &&
                    streamHeight in 1..panelHeight &&
                    streamWidth.toFloat() / panelWidth >= DIRECT_PIXEL_MIN_SCALE &&
                    streamHeight.toFloat() / panelHeight >= DIRECT_PIXEL_MIN_SCALE
            val targetWidth = if (nearNative) streamWidth else 0
            val targetHeight = if (nearNative) streamHeight else 0
            val params = binding.surfaceView.layoutParams as ConstraintLayout.LayoutParams
            if (params.width != targetWidth || params.height != targetHeight) {
                params.width = targetWidth
                params.height = targetHeight
                binding.surfaceView.layoutParams = params
            }
            mainDiag(
                "Surface mapping: ${if (usbColorBridgeOn) "GPU upscale/fill" else if (nearNative) "1:1" else "fill"} " +
                    "stream=${streamWidth}x$streamHeight panel=${panelWidth}x$panelHeight",
            )
        }
    }

    private var vsrCmdReceiver: BroadcastReceiver? = null
    private var labCmdReceiver: BroadcastReceiver? = null
    private val labCaptureHandler = Handler(Looper.getMainLooper())

    /** Debug A/B hook: adb broadcast to switch VSR modes headlessly (no UI taps, no reconnect). */
    private fun setupVsrCommandReceiver() {
        if (vsrCmdReceiver != null) return
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(
                    context: Context?,
                    intent: Intent?,
                ) {
                    val i = intent ?: return
                    if (i.action != VSR_CMD_ACTION) return
                    val mode = i.getStringExtra("mode")
                    val directUsbProfilePath =
                        hasActiveSession &&
                            prefs.connectionMode == ConnectionMode.USB &&
                            !prefs.vsrEnabled &&
                            supportsGles31() &&
                            !shouldUseTextureView()
                    val profileChangesVideoPath = i.hasExtra("color_profile") && directUsbProfilePath
                    val changesVideoPath =
                        mode != null ||
                            i.hasExtra("enabled") ||
                            i.hasExtra("sharpness") ||
                            i.hasExtra("cfl_strength") ||
                            i.hasExtra("edge_threshold") ||
                            profileChangesVideoPath
                    val enabled =
                        if (i.hasExtra("enabled")) {
                            i.getBooleanExtra("enabled", false)
                        } else {
                            mode != null || prefs.vsrEnabled
                        }
                    mode?.let { prefs.vsrMode = it }
                    i.getFloatExtra("sharpness", -1f).takeIf { it >= 0f }?.let { prefs.vsrSharpness = it }
                    i.getFloatExtra("cfl_strength", -1f).takeIf { it >= 0f }?.let { prefs.cflStrength = it }
                    i.getFloatExtra("edge_threshold", -1f).takeIf { it >= 0f }?.let { prefs.vsrEdgeThreshold = it }
                    if (changesVideoPath) prefs.vsrEnabled = enabled
                    if (i.hasExtra("color_profile")) {
                        val profileEnabled = i.getBooleanExtra("color_profile", AndroidColorProfile.DEFAULT_ENABLED)
                        prefs.androidColorProfileEnabled = profileEnabled
                        if (!profileChangesVideoPath) {
                            sgsrRenderer?.setAndroidColorProfileEnabled(profileEnabled)
                            cflRenderer?.setAndroidColorProfileEnabled(profileEnabled)
                        }
                    }
                    mainDiag(
                        "VSR_CMD: enabled=${if (changesVideoPath) enabled else prefs.vsrEnabled} " +
                            "mode=${prefs.vsrMode} colorProfile=${prefs.androidColorProfileEnabled}",
                    )
                    if (changesVideoPath) restartVideoPath()
                }
            }
        val filter = IntentFilter(VSR_CMD_ACTION)
        ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_EXPORTED)
        vsrCmdReceiver = receiver
    }

    /**
     * Opt-in Android-side evaluation controls. The shell runner uses these
     * commands to capture the actual SurfaceView with PixelCopy, render the
     * native control image, and export raw per-frame timing. Ordinary launches
     * never send these commands and keep the normal connection path unchanged.
     */
    private fun setupLabCommandReceiver() {
        if (labCmdReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val command = intent ?: return
                if (command.action != LAB_CMD_ACTION) return
                when (command.getStringExtra("op")) {
                    "native_capture" -> {
                        val labIntent = Intent(this@MainActivity, LabActivity::class.java)
                            .putExtra(
                                LabActivity.EXTRA_SOURCE_PATH,
                                command.getStringExtra("source_path"),
                            )
                            .putExtra(
                                LabActivity.EXTRA_OUTPUT_NAME,
                                command.getStringExtra("output_name") ?: "native.png",
                            )
                        startActivity(labIntent)
                    }
                    "surface_capture" -> {
                        val outputName = command.getStringExtra("output_name") ?: "streamed.png"
                        val expectedWidth = command.getIntExtra("expected_width", 0)
                        val expectedHeight = command.getIntExtra("expected_height", 0)
                        // Wait for the first real frame to transition the
                        // activity into stream-only presentation. Before
                        // that transition the control shell still owns the
                        // system bars, so a PixelCopy would be the wrong
                        // surface size for an exact corpus comparison.
                        labCaptureHandler.postDelayed({
                            captureLabSurface(outputName, expectedWidth, expectedHeight)
                        }, LAB_SURFACE_CAPTURE_DELAY_MS)
                    }
                    "trace_start" -> {
                        val name = command.getStringExtra("output_name") ?: "frame-trace.csv"
                        val file = FrameTraceRecorder.start(applicationContext, name)
                        mainDiag("LAB trace started path=${file.absolutePath}")
                    }
                    "trace_stop" -> {
                        FrameTraceRecorder.stop()
                        mainDiag("LAB trace stopped")
                    }
                    else -> mainDiag("LAB ignored unknown command")
                }
            }
        }
        ContextCompat.registerReceiver(
            this,
            receiver,
            IntentFilter(LAB_CMD_ACTION),
            ContextCompat.RECEIVER_EXPORTED,
        )
        labCmdReceiver = receiver
    }

    private fun captureLabSurface(
        requestedName: String,
        expectedWidth: Int = 0,
        expectedHeight: Int = 0,
        attempt: Int = 0,
    ) {
        val holder = currentSurfaceHolder
        if (holder == null || !holder.surface.isValid) {
            retryLabSurfaceCapture(
                requestedName,
                expectedWidth,
                expectedHeight,
                attempt,
                "SurfaceView surface unavailable",
            )
            return
        }
        val frame = holder.surfaceFrame
        val width = frame.width()
        val height = frame.height()
        if (width <= 0 || height <= 0) {
            retryLabSurfaceCapture(
                requestedName,
                expectedWidth,
                expectedHeight,
                attempt,
                "invalid surface size ${width}x$height",
            )
            return
        }
        if (expectedWidth > 0 && expectedHeight > 0 &&
            (width != expectedWidth || height != expectedHeight)
        ) {
            retryLabSurfaceCapture(
                requestedName,
                expectedWidth,
                expectedHeight,
                attempt,
                "surface size ${width}x$height; expected ${expectedWidth}x$expectedHeight",
            )
            return
        }
        val safeName = requestedName
            .replace(Regex("[^A-Za-z0-9_.-]"), "_")
            .ifBlank { "streamed.png" }
        val output = File(File(filesDir, "lab"), safeName)
        output.parentFile?.mkdirs()
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        PixelCopy.request(
            holder.surface,
            bitmap,
            { result ->
                if (result == PixelCopy.SUCCESS) {
                    runCatching {
                        output.outputStream().use { stream ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                        }
                        mainDiag(
                            "LAB streamed PixelCopy PASS path=${output.absolutePath} " +
                                "surface=${width}x$height",
                        )
                    }.onFailure { error ->
                        mainDiag("LAB streamed PixelCopy write failed: ${error.message}")
                    }
                } else {
                    retryLabSurfaceCapture(
                        requestedName,
                        expectedWidth,
                        expectedHeight,
                        attempt,
                        "PixelCopy result=$result surface=${width}x$height",
                    )
                }
                bitmap.recycle()
            },
            Handler(Looper.getMainLooper()),
        )
    }

    private fun retryLabSurfaceCapture(
        requestedName: String,
        expectedWidth: Int,
        expectedHeight: Int,
        attempt: Int,
        reason: String,
    ) {
        if (attempt >= LAB_SURFACE_CAPTURE_RETRY_LIMIT) {
            mainDiag("LAB streamed PixelCopy gave up after ${attempt + 1} attempts: $reason")
            return
        }
        mainDiag(
            "LAB streamed PixelCopy retry ${attempt + 1}/$LAB_SURFACE_CAPTURE_RETRY_LIMIT: $reason",
        )
        labCaptureHandler.postDelayed({
            captureLabSurface(
                requestedName,
                expectedWidth,
                expectedHeight,
                attempt + 1,
            )
        }, LAB_SURFACE_CAPTURE_RETRY_DELAY_MS)
    }

    private fun activeVideoSurface(): Pair<Surface, Boolean>? {
        return if (shouldUseTextureView()) {
            currentTextureSurface?.takeIf { it.isValid }?.let { it to true }
        } else {
            currentSurfaceHolder?.surface?.takeIf { it.isValid }?.let { it to false }
        }
    }

    private fun initializeDecoderForCurrentSurface(
        generation: Long,
        ownerClient: StreamClient? = streamClient,
    ) {
        if (!sessionController.canInitializeDecoder(generation)) {
            mainDiag("initializeDecoder skipped — session not ready generation=$generation")
            return
        }
        if (displayWidth <= 0 || displayHeight <= 0) {
            mainDiag("initializeDecoder skipped — no display config yet")
            return
        }
        // AVC-only device: an HEVC decoder can never decode the H.264 stream
        // the Mac will send — defer until codecSelected arrives, then
        // onStreamCodecSelected initializes with the correct mime.
        if (!CodecCapabilities.hasHevcDecoder && ownerClient?.codecNegotiated != true) {
            mainDiag("initializeDecoder deferred — AVC-only device awaiting codec negotiation")
            return
        }

        val (surface, useTextureView) =
            activeVideoSurface() ?: run {
                val kind = if (shouldUseTextureView()) "TextureView" else "SurfaceView"
                mainDiag("initializeDecoder skipped — no valid $kind surface")
                return
            }

        if (videoDecoder != null && decoderUsingTextureView == useTextureView && sgsrRenderer == null && cflRenderer == null) {
            videoDecoder?.updateResolution(displayWidth, displayHeight)
            return
        }

        videoDecoder?.release()
        videoDecoder = null
        sgsrRenderer?.release()
        sgsrRenderer = null
        cflRenderer?.release()
        cflRenderer = null
        decoderUsingTextureView = useTextureView

        mainDiag(
            "initializeDecoder called, surface=$surface, valid=${surface.isValid}, " +
                "res=${displayWidth}x$displayHeight, texture=$useTextureView",
        )
        try {
            val displayObj =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    display
                } else {
                    @Suppress("DEPRECATION")
                    windowManager.defaultDisplay
                }
            val mime =
                if (ownerClient?.streamCodecIsHevc == false) {
                    MediaFormat.MIMETYPE_VIDEO_AVC
                } else {
                    MediaFormat.MIMETYPE_VIDEO_HEVC
                }
            var decoderSurface = surface
            val cflOn = prefs.vsrEnabled && prefs.vsrMode.equals("cfl", true) &&
                supportsGles31() && !useTextureView
            val vsrOn = prefs.vsrEnabled && supportsGles31() && !useTextureView && !cflOn
            val usbColorBridgeOn = isUsbColorBridgePathActive() && !cflOn && !vsrOn
            if (cflOn) {
                // CfL chroma reconstruction via ByteBuffer-mode decode: the
                // decoder is configured WITHOUT a surface and hands
                // plane-accessible Images to the renderer (the ImageReader
                // route is dead on this SoC — opaque UBWC buffers whose
                // plane access is a fatal JNI abort).
                try {
                    val renderer = CflRenderer()
                    renderer.initialize(surface, displayWidth, displayHeight)
                    renderer.onStats = { s ->
                        mainDiag("VSR stats: ${s.summary()}")
                        runOnUiThread { binding.vsrText.text = s.summary() }
                    }
                    val unavailable: (String) -> Unit = { reason ->
                        mainDiag("CfL unavailable ($reason) — disabling, direct path")
                        runOnUiThread {
                            prefs.vsrEnabled = false
                            binding.vsrText.text = "cfl fallback"
                            restartVideoPath()
                        }
                    }
                    renderer.onPlanesUnavailable = unavailable
                    renderer.setStrength(prefs.cflStrength)
                    renderer.setAndroidColorProfileEnabled(prefs.androidColorProfileEnabled)
                    cflRenderer = renderer
                    mainDiag(
                        "CfL active (luma-guided chroma reconstruction, buffer decode) " +
                            "colorProfile=${prefs.androidColorProfileEnabled}",
                    )
                } catch (e: Exception) {
                    mainDiag("CfL init failed (${e.message}) — falling back to direct surface")
                    cflRenderer?.release()
                    cflRenderer = null
                    runOnUiThread { binding.vsrText.text = "fallback" }
                }
            } else if (vsrOn || usbColorBridgeOn) {
                try {
                    val renderer = SgsrRenderer(
                        applicationContext,
                        frameRateCap = if (usbColorBridgeOn) {
                            AndroidColorProfile.USB_BRIDGE_FPS_CAP
                        } else {
                            null
                        },
                    )
                    renderer.initialize(surface, displayWidth, displayHeight)
                    renderer.setMode(
                        if (usbColorBridgeOn) {
                            SgsrRenderer.Mode.BRIDGE_ONLY
                        } else {
                            SgsrRenderer.Mode.from(prefs.vsrMode)
                        },
                    )
                    renderer.setSharpness(prefs.vsrSharpness)
                    renderer.setEdgeThreshold(prefs.vsrEdgeThreshold)
                    renderer.setAndroidColorProfileEnabled(prefs.androidColorProfileEnabled)
                    renderer.onStats = { s ->
                        mainDiag(
                            "VSR stats: ${s.summary()} " +
                                "p95=${"%.1f".format(s.cpuP95Ms)}ms",
                        )
                        runOnUiThread { binding.vsrText.text = s.summary() }
                    }
                    sgsrRenderer = renderer
                    decoderSurface = renderer.decoderSurfaceRef ?: surface
                    if (usbColorBridgeOn) {
                        mainDiag(
                            "USB color bridge active: sRGB / BT.709 profile=" +
                                "${prefs.androidColorProfileEnabled} " +
                                "fpsCap=${AndroidColorProfile.USB_BRIDGE_FPS_CAP}",
                        )
                    } else {
                        mainDiag(
                            "VSR active: mode=${prefs.vsrMode} sharpness=${prefs.vsrSharpness} " +
                                "colorProfile=${prefs.androidColorProfileEnabled}",
                        )
                    }
                } catch (e: Exception) {
                    mainDiag("VSR init failed (${e.message}) — falling back to direct surface")
                    sgsrRenderer?.release()
                    sgsrRenderer = null
                    runOnUiThread { binding.vsrText.text = "fallback" }
                }
            } else {
                runOnUiThread {
                    binding.vsrText.text =
                        if (prefs.vsrEnabled) "n/a" else "off"
                }
            }
            val useBufferOutput = cflRenderer != null
            videoDecoder = VideoDecoder(
                decoderSurface,
                displayObj,
                displayWidth,
                displayHeight,
                mime,
                targetFrameRate = when {
                    prefs.connectionMode == ConnectionMode.WIRELESS ->
                        WirelessTransportProfile.TARGET_FPS
                    usbColorBridgeOn -> AndroidColorProfile.USB_BRIDGE_FPS_CAP
                    else -> null
                },
                bufferOutput = useBufferOutput,
            )
            videoDecoder?.onColorRange = { range ->
                val fullRange = range != 2
                sgsrRenderer?.setFullRange(fullRange)
                cflRenderer?.setFullRange(fullRange)
            }
            if (useBufferOutput) {
                cflRenderer?.let { renderer ->
                    videoDecoder?.onDecodedImage = { img, done ->
                        renderer.submitImage(img) {
                            done()
                            if (sessionController.isCurrent(generation)) {
                                sessionController.frameDecoded(generation)
                                sessionController.surfaceRendered(generation)
                            }
                        }
                    }
                    videoDecoder?.onImageOutputUnavailable = {
                        runOnUiThread {
                            prefs.vsrEnabled = false
                            binding.vsrText.text = "cfl fallback"
                            restartVideoPath()
                        }
                    }
                }
            }
            videoDecoder?.onDecodeLatency = { avgMs, maxMs ->
                mainDiag("decode latency avg=" + "%.1f".format(avgMs) + "ms max=" + "%.1f".format(maxMs) + "ms")
            }
            videoDecoder?.onFrameTrace = { trace ->
                FrameTraceRecorder.record(trace)
            }
            videoDecoder?.onDecodedFormat = { w, h, cl, cr, ct, cb ->
                mainDiag("decoder output format ${w}x$h crop=$cl,$cr,$ct,$cb")
                // CfL renderer self-sizes its textures from the first Image.
                sgsrRenderer?.resizeStream(w, h, cl, cr, ct, cb)
            }
            videoDecoder?.onFirstFrameDecoded = {
                if (sessionController.isCurrent(generation)) {
                    sessionController.frameDecoded(generation)
                }
            }
            videoDecoder?.onFrameRendered = { _ ->
                if (sessionController.isCurrent(generation)) {
                    sessionController.surfaceRendered(generation)
                }
            }
            videoDecoder?.onFrameDecoded = { buffer ->
                ownerClient?.releaseBuffer(buffer)
            }
            videoDecoder?.onKeyframeRequired = { force, reason ->
                if (ownerClient != null && isCurrentConnection(ownerClient, generation)) {
                    ownerClient.requestKeyframe(force = force, reason = reason)
                }
            }
            videoDecoder?.onDecoderStalled = {
                // Black screen with live stats: tell the user why instead of
                // staying silent (issue #41). Toast renders above the (black)
                // SurfaceView; the settings panel is hidden while streaming.
                val cap = CodecCapabilities.maxDecodeSize(mime)
                runOnUiThread {
                    val capText = cap?.let { " (max ~${it.first}×${it.second})" } ?: ""
                    android.widget.Toast
                        .makeText(
                            this,
                            "No video output — the stream resolution may exceed " +
                                "this tablet's decoder limit$capText. " +
                                "Lower the resolution or disable HiDPI on the Mac.",
                            android.widget.Toast.LENGTH_LONG,
                        ).show()
                }
            }
            sessionController.decoderStarted(generation)
            ownerClient?.requestKeyframe(force = true, reason = "decoder initialized")
            mainDiag("Decoder initialized OK ${displayWidth}x$displayHeight mime=$mime, texture=$useTextureView")
            val effectiveDecoderRate = when {
                prefs.connectionMode == ConnectionMode.WIRELESS ->
                    WirelessTransportProfile.TARGET_FPS.toFloat()
                usbColorBridgeOn -> AndroidColorProfile.USB_BRIDGE_FPS_CAP.toFloat()
                else -> displayObj?.refreshRate ?: 60f
            }
            log("✅ Decoder initialized ${displayWidth}x$displayHeight $mime (${effectiveDecoderRate}Hz target)")
        } catch (e: Exception) {
            decoderUsingTextureView = false
            mainDiag("Decoder init FAILED: ${e.message}")
            log("❌ Failed to initialize decoder: ${e.message}")
            sessionController.fail(generation, "Video decoder failed: ${e.message ?: "unknown decoder error"}")
            runOnUiThread {
                updateStatus("Video decoder failed: ${e.message}")
            }
        }
    }

    /** Render all connection UI from SessionController. Checklist/preflight
     * state is advisory and cannot overwrite an active generation. */
    private fun renderSessionState(state: SessionController.State) {
        val active = state is SessionController.State.Connecting ||
            state is SessionController.State.Negotiating ||
            state is SessionController.State.WaitingForFirstFrame ||
            state is SessionController.State.Streaming
        val streaming = state is SessionController.State.Streaming

        when (state) {
            SessionController.State.Idle -> {
                presentationController.release()
                releaseVideoPipeline()
                binding.settingsPanel.visibility = View.VISIBLE
                binding.settingsButton.visibility = View.GONE
                binding.statusBar.visibility = View.GONE
                binding.connectButton.isEnabled = true
                binding.disconnectButton.isEnabled = false
                setStatusIndicator(R.drawable.status_indicator_amber)
                updateStatus("Ready — tap Connect to start")
            }

            is SessionController.State.Preflight -> {
                presentationController.release()
                releaseVideoPipeline()
                binding.settingsPanel.visibility = View.VISIBLE
                binding.settingsButton.visibility = View.GONE
                binding.statusBar.visibility = View.GONE
                binding.connectButton.isEnabled = true
                binding.disconnectButton.isEnabled = false
                setStatusIndicator(R.drawable.status_indicator_amber)
                updateStatus(
                    if (state.advisories.isEmpty()) {
                        "Ready — tap Connect to start"
                    } else {
                        "Ready — USB checks are advisory; tap Connect to verify"
                    },
                )
            }

            is SessionController.State.Connecting -> {
                presentationController.release()
                binding.settingsPanel.visibility = View.VISIBLE
                binding.settingsButton.visibility = View.GONE
                binding.statusBar.visibility = View.GONE
                binding.connectButton.isEnabled = false
                binding.disconnectButton.isEnabled = true
                setStatusIndicator(R.drawable.status_indicator_amber)
                updateStatus("Connecting…")
                stopChecklistUpdates()
            }

            is SessionController.State.Negotiating -> {
                presentationController.release()
                binding.settingsPanel.visibility = View.VISIBLE
                binding.settingsButton.visibility = View.GONE
                binding.statusBar.visibility = View.GONE
                binding.connectButton.isEnabled = false
                binding.disconnectButton.isEnabled = true
                setStatusIndicator(R.drawable.status_indicator_amber)
                updateStatus("Connected · negotiating display")
                stopChecklistUpdates()
                if (state.details.mode == ConnectionMode.WIRELESS) {
                    val entry = pairedHostStorage.load()
                    wirelessController.onConnectSuccess(entry?.macName ?: "Mac", entry?.host ?: "—")
                }
            }

            is SessionController.State.WaitingForFirstFrame -> {
                presentationController.release()
                binding.settingsPanel.visibility = View.GONE
                binding.settingsButton.visibility = View.GONE
                binding.statusBar.visibility = View.GONE
                binding.connectButton.isEnabled = false
                binding.disconnectButton.isEnabled = true
                setStatusIndicator(R.drawable.status_indicator_amber)
                updateStatus("Connected · waiting for first rendered frame")
                stopChecklistUpdates()
            }

            is SessionController.State.Streaming -> {
                presentationController.acquire(state.details.generation)
                binding.settingsPanel.visibility = View.GONE
                binding.connectButton.isEnabled = false
                binding.disconnectButton.isEnabled = true
                setStatusIndicator(
                    if (state.details.control == SessionController.ControlHealth.DEGRADED) {
                        R.drawable.status_indicator_amber
                    } else {
                        R.drawable.status_indicator_green
                    },
                )
                updateStatus(
                    if (state.details.control == SessionController.ControlHealth.DEGRADED) {
                        "Streaming · control degraded; video healthy"
                    } else {
                        "Connected · streaming active"
                    },
                )
                applySettingsButtonVisibility()
                restoreSettingsButtonPosition()
                updateOverlayVisibility(prefs.showStatsOverlay)
                stopChecklistUpdates()
                if (pendingBrightnessGeneration == state.details.generation) {
                    pendingBrightness?.let { applyBacklight(state.details.generation, it) }
                    pendingBrightnessGeneration = null
                    pendingBrightness = null
                }
                if (state.details.mode == ConnectionMode.WIRELESS) {
                    val entry = pairedHostStorage.load()
                    wirelessController.onConnectSuccess(entry?.macName ?: "Mac", entry?.host ?: "—")
                }
            }

            is SessionController.State.Disconnecting -> {
                presentationController.release()
                stopPingTimer()
            }

            is SessionController.State.Disconnected -> {
                presentationController.release()
                releaseVideoPipeline()
                binding.settingsPanel.visibility = View.VISIBLE
                binding.settingsButton.visibility = View.GONE
                binding.statusBar.visibility = View.GONE
                binding.connectButton.isEnabled = true
            binding.disconnectButton.isEnabled = false
            setStatusIndicator(R.drawable.status_indicator_amber)
            updateStatus("Ready — tap Connect to start")
            log("Disconnected — ${state.reason}; automatic reconnect is disabled")
                if (prefs.connectionMode == ConnectionMode.WIRELESS) {
                    wirelessController.onStreamDisconnected()
                } else if (restartChecklistAfterDisconnect) {
                    startChecklistUpdates()
                }
            }

            is SessionController.State.Failed -> {
                presentationController.release()
                releaseVideoPipeline()
                binding.settingsPanel.visibility = View.VISIBLE
                binding.settingsButton.visibility = View.GONE
                binding.statusBar.visibility = View.GONE
                binding.connectButton.isEnabled = true
                binding.disconnectButton.isEnabled = false
                setStatusIndicator(R.drawable.status_indicator_red)
                updateStatus("Connection failed · tap Connect to retry")
                startChecklistUpdates()
            }
        }

        if (!active && !streaming && state !is SessionController.State.Disconnecting) {
            updateScreenPowerState(false)
        }
    }

    /** One callback route for USB and wireless. The controller owns all UI
     * truth; this method only reports transport/protocol/render evidence. */
    private fun setupStreamClientCallbacks(client: StreamClient, generation: Long) {
        client.onFrameReceived = frameReceived@{ frameData, frameSize, timestamp, isKeyframe, trace ->
            if (!isCurrentConnection(client, generation)) {
                client.releaseBuffer(frameData)
                return@frameReceived
            }
            val dec = videoDecoder
            if (dec != null) {
                dec.decode(frameData, frameSize, timestamp, isKeyframe, trace = trace)
            } else {
                mainDiag("FRAME DROPPED: videoDecoder is null!")
                client.releaseBuffer(frameData)
            }
        }

        client.onLatencyMeasured = { rttMs ->
            if (isCurrentConnection(client, generation)) {
                runOnUiThread {
                    if (isCurrentConnection(client, generation)) {
                        binding.latencyText.text = String.format("%.1f ms", rttMs)
                    }
                }
            }
        }

        client.onBrightness = brightnessCommand@{ value ->
            if (!isCurrentConnection(client, generation)) return@brightnessCommand
            if (sessionController.ownsBrightness(generation)) {
                applyBacklight(generation, value)
            } else {
                // Host replay may arrive before the first Surface render. Keep
                // it only for this current generation and apply it when the
                // session legitimately acquires brightness ownership.
                pendingBrightnessGeneration = generation
                pendingBrightness = value
                mainDiag("BRIGHT queued until Streaming generation=$generation value=$value")
            }
        }

        client.onControlChannelState = { healthy ->
            if (isCurrentConnection(client, generation)) {
                sessionController.controlHealthy(generation, healthy)
            }
        }

        client.onConnectionStatus = connectionStatus@{ connected ->
            if (!isCurrentConnection(client, generation)) {
                if (connected) client.disconnect()
                return@connectionStatus
            }
            if (connected) {
                sessionController.transportConnected(generation)
                startPingTimer()
                stopChecklistUpdates()
            } else {
                stopPingTimer()
                sessionController.transportLost(generation)
            }
        }

        client.onCodecSelected = { isHevc ->
            if (isCurrentConnection(client, generation)) {
                sessionController.protocolNegotiated(generation)
                onStreamCodecSelected(generation, isHevc)
            }
        }

        client.onDisplaySize = displayConfig@{ width, height, rotation, flipHorizontal, flipVertical ->
            if (!isCurrentConnection(client, generation)) return@displayConfig
            mainDiag("onDisplaySize: ${width}x$height @ $rotation°, h=$flipHorizontal, v=$flipVertical")
            warnIfAvcOnlyWithoutNegotiation(client)
            sessionController.displayConfigured(generation, legacyProtocolAccepted = true)
            displayWidth = width
            displayHeight = height
            displayRotation = rotation
            displayFlipHorizontal = flipHorizontal
            displayFlipVertical = flipVertical
            runOnUiThread {
                if (!isCurrentConnection(client, generation)) return@runOnUiThread
                binding.resolutionText.text = "${width}x$height"
                applyRotation(rotation, flipHorizontal, flipVertical)
                applyDirectPixelMapping(width, height)
                initializeDecoderForCurrentSurface(generation, client)
            }
            log("Display: ${width}x$height @ $rotation°")
        }

        client.onStats = { fps, mbps ->
            if (isCurrentConnection(client, generation)) {
                runOnUiThread {
                    if (isCurrentConnection(client, generation)) {
                        binding.fpsText.text = String.format("%.1f", fps)
                        binding.bitrateText.text = String.format("%.1f Mbps", mbps)
                    }
                }
            }
        }
    }

    private fun connectWireless(
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
    ) {
        val generation = beginConnection(ConnectionMode.WIRELESS)
        val client = StreamClient(host, port, applicationContext)
        streamClient = client
        setupStreamClientCallbacks(client, generation)
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting wirelessly to $host:$port...")
                client.connectWireless(token, deviceName)
            } catch (e: StreamClient.WirelessConnectError) {
                if (isCurrentConnection(client, generation)) {
                    sessionController.fail(generation, e.message ?: "Wireless connection failed")
                    runOnUiThread { wirelessController.onConnectError(e) }
                }
            } catch (e: Exception) {
                if (isCurrentConnection(client, generation)) {
                    log("Wireless connect failed: ${e.message}")
                    sessionController.fail(generation, e.message ?: "Wireless connection failed")
                    runOnUiThread {
                        wirelessController.onConnectError(StreamClient.WirelessConnectError.NetworkUnreachable)
                    }
                }
            }
        }
    }

    private fun connect(
        host: String,
        port: Int,
    ) {
        val generation = beginConnection(ConnectionMode.USB)

        val client =
            StreamClient(
                host,
                port,
                applicationContext,
                controlHost = host,
                controlPort = port + 1,
            )
        streamClient = client
        setupStreamClientCallbacks(client, generation)

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting to $host:$port...")
                client.connect()
            } catch (e: Exception) {
                if (!isCurrentConnection(client, generation)) return@launch
                val errorMessage =
                    when {
                        e.message?.contains("ECONNREFUSED") == true -> {
                            "Mac server is not running.\n\nPlease start Tablet Bridge.app on your Mac first."
                        }

                        e.message?.contains("Network is unreachable") == true -> {
                            "Cannot reach Mac.\n\n" +
                                "Make sure both devices are connected via USB cable and ADB reverse is configured."
                        }

                        e.message?.contains("timeout") == true -> {
                            "Connection timeout.\n\nCheck if Mac firewall is blocking port $port."
                        }

                        else -> {
                            "Connection failed: ${e.message}\n\n" +
                                "Try:\n• Start Tablet Bridge.app on Mac\n" +
                                "• Check USB connection\n• Run: adb reverse tcp:$port tcp:$port"
                        }
                }
                runOnUiThread {
                    if (!isCurrentConnection(client, generation)) return@runOnUiThread
                    sessionController.fail(generation, errorMessage)
                    showError(errorMessage)
                }
            }
        }
    }

    private fun beginConnection(mode: ConnectionMode): Long {
        restartChecklistAfterDisconnect = true
        val generation = sessionController.begin(mode)
        pendingBrightnessGeneration = null
        pendingBrightness = null
        streamClient?.disconnect()
        streamClient = null
        releaseVideoPipeline()
        displayWidth = 0
        displayHeight = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        return generation
    }

    private fun isCurrentConnection(
        client: StreamClient,
        generation: Long,
    ): Boolean = sessionController.isCurrent(generation) && streamClient === client

    private fun disconnect(restartChecklist: Boolean = true) {
        restartChecklistAfterDisconnect = restartChecklist
        stopPingTimer()
        presentationController.release()
        sessionController.disconnect("user requested disconnect")
        val client = streamClient
        streamClient = null
        client?.disconnect()
        releaseVideoPipeline()
        // Reset display config so next connect defers decoder init until config arrives
        displayWidth = 0
        displayHeight = 0
        displayRotation = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        val resetUi = {
            updateScreenPowerState(false)
            applyDirectPixelMapping(0, 0)
            binding.textureView.visibility = View.GONE
            applyTextureTransform()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) resetUi() else runOnUiThread(resetUi)
    }

    private fun releaseVideoPipeline() {
        videoDecoder?.release()
        videoDecoder = null
        sgsrRenderer?.release()
        sgsrRenderer = null
        cflRenderer?.release()
        cflRenderer = null
    }

    private fun startPingTimer() {
        stopPingTimer()
        pingJob =
            lifecycleScope.launch(Dispatchers.IO) {
                while (true) {
                    kotlinx.coroutines.delay(LATENCY_PING_INTERVAL_MS)
                    streamClient?.sendPing()
                }
            }
    }

    private fun stopPingTimer() {
        pingJob?.cancel()
        pingJob = null
    }

    private fun cleanup() {
        try {
            labCaptureHandler.removeCallbacksAndMessages(null)
            labCmdReceiver?.let {
                unregisterReceiver(it)
                labCmdReceiver = null
            }
            vsrCmdReceiver?.let {
                unregisterReceiver(it)
                vsrCmdReceiver = null
            }
            FrameTraceRecorder.stop()
            disconnect(restartChecklist = false)
            currentTextureSurface?.release()
            currentTextureSurface = null
        } catch (e: Exception) {
            log("⚠️ Cleanup error: ${e.message}")
        }
    }

    private fun handleTouch(
        view: View,
        event: MotionEvent,
    ) {
        val rawX = event.x / view.width.toFloat()
        val rawY = event.y / view.height.toFloat()
        val x = if (displayFlipHorizontal) 1f - rawX else rawX
        val y = if (displayFlipVertical) 1f - rawY else rawY
        val pointerCount = event.pointerCount.coerceAtMost(2)

        var x2 = 0f
        var y2 = 0f
        if (pointerCount >= 2) {
            val rawX2 = event.getX(1) / view.width.toFloat()
            val rawY2 = event.getY(1) / view.height.toFloat()
            x2 = if (displayFlipHorizontal) 1f - rawX2 else rawX2
            y2 = if (displayFlipVertical) 1f - rawY2 else rawY2
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                inputPredictor.reset()
                inputPredictor.addSample(x, y)
                streamClient?.sendTouch(x, y, 0, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                streamClient?.sendTouch(x, y, 0, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_MOVE -> {
                if (pointerCount == 1) {
                    inputPredictor.addSample(x, y)
                    val (px, py) = inputPredictor.predictPosition(12f)
                    streamClient?.sendTouch(px, py, 1, 1)
                } else {
                    streamClient?.sendTouch(x, y, 1, pointerCount, x2, y2)
                }
            }

            MotionEvent.ACTION_UP -> {
                inputPredictor.reset()
                streamClient?.sendTouch(x, y, 2, 1)
            }

            MotionEvent.ACTION_POINTER_UP -> {
                streamClient?.sendTouch(x, y, 2, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_CANCEL -> {
                inputPredictor.reset()
                streamClient?.sendTouch(x, y, 2, 1)
            }
        }
    }

    private fun applyRotation(
        rotation: Int,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
    ) {
        // The stream may negotiate its geometry while the app is still in the
        // idle/control shell. PresentationController applies orientation only
        // once the current generation reaches Streaming.
        presentationController.setPendingRotation(rotation)

        binding.surfaceView.rotation = 0f
        binding.surfaceView.visibility = View.VISIBLE
        binding.textureView.visibility = if (flipHorizontal || flipVertical) View.VISIBLE else View.GONE
        applyTextureTransform()

        log(
            "🔄 Orientation: ${when (rotation) {
                90 -> "Portrait"
                180 -> "Landscape (flipped)"
                270 -> "Portrait (flipped)"
                else -> "Landscape"
            }}${if (flipHorizontal || flipVertical) " mirrored" else ""}",
        )
    }

    private fun applyTextureTransform() {
        val view = binding.textureView
        val matrix = Matrix()
        val centerX = view.width / 2f
        val centerY = view.height / 2f
        matrix.postScale(
            if (displayFlipHorizontal) -1f else 1f,
            if (displayFlipVertical) -1f else 1f,
            centerX,
            centerY,
        )
        view.setTransform(matrix)
    }

    private fun log(message: String) {
        runOnUiThread {
            val current = binding.logText.text.toString()
            val lines = current.split("\n").takeLast(5)
            binding.logText.text = (lines + message).joinToString("\n")
        }
    }

    override fun onStart() {
        super.onStart()
        // Back in the foreground — cancel any pending auto-disconnect.
        backgroundedAtMs = 0L
        autoDisconnectJob?.cancel()
        autoDisconnectJob = null
        updateScreenPowerState(sessionController.isStreaming())
        if (hasActiveSession) {
            startPingTimer()
        }
        if (!hasActiveSession && prefs.connectionMode == ConnectionMode.USB) {
            startChecklistUpdates()
        }
    }

    override fun onStop() {
        super.onStop()
        updateScreenPowerState(false)
        stopPingTimer()
        // Backgrounded while streaming: arm the auto-disconnect timer.
        if (!hasActiveSession) return
        backgroundedAtMs = System.currentTimeMillis()
        val secs =
            Settings.System.getInt(contentResolver, "sidescreen_auto_disconnect_secs", DEFAULT_BACKGROUND_DISCONNECT_SECS)
                .coerceAtLeast(10)
        autoDisconnectJob =
            lifecycleScope.launch {
                delay(secs * 1000L)
                if (
                    sessionController.isStreaming() &&
                    backgroundedAtMs > 0 &&
                    System.currentTimeMillis() - backgroundedAtMs >= secs * 1000L
                ) {
                    DiagLog.log("MA", "auto-disconnect: backgrounded > ${secs}s — tearing down session")
                    disconnect(restartChecklist = false)
                }
            }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopChecklistUpdates()
        cleanup()
    }

    // ==================== Connection Checklist ====================

    private fun startChecklistUpdates() {
        // Stop any existing runnable first to prevent duplicates
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
        }

        checklistRunnable =
            object : Runnable {
                override fun run() {
                    updateChecklist()
                    checklistHandler.postDelayed(this, CHECKLIST_INTERVAL_MS) // Local checks only; no host polling
                }
            }
        checklistHandler.post(checklistRunnable!!)
    }

    private fun stopChecklistUpdates() {
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
            checklistRunnable = null
        }
    }

    private fun updateChecklist() {
        // Checklist/preflight is advisory only and never runs against an
        // active generation. It does not probe the host or USB deviceList.
        if (hasActiveSession) return

        // Check Developer Mode (if we can run this app with USB debugging, dev mode is enabled)
        val isDeveloperModeEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkDeveloperMode, isDeveloperModeEnabled)

        // Check USB Debugging (ADB enabled)
        val isAdbEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.ADB_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkUsbDebugging, isAdbEnabled)

        // UsbManager.deviceList describes Android acting as a USB host. In
        // SideScreen the Mac is host and this tablet is the USB device, so it
        // is a false-negative for adb reverse. Keep it visibly advisory.
        binding.textUsbConnected.text = "USB route · verified when you tap Connect"
        updateChecklistPending(binding.checkUsbConnected)

        // The Mac server is intentionally not probed while idle. A TCP probe
        // is still a screen-sharing connection from the host's perspective,
        // and can contend with the real client. The first explicit Connect
        // is the only server check.
        binding.textMacServer.text = "Mac server · checked when you tap Connect"
        updateChecklistPending(binding.checkMacServer)

        val advisories = buildList {
            if (!isDeveloperModeEnabled) add("Developer mode is not reported")
            if (!isAdbEnabled) add("ADB debugging is not reported")
        }
        sessionController.setPreflight(advisories)
    }

    private fun updateChecklistItem(
        indicator: View,
        isOk: Boolean,
    ) {
        indicator.setBackgroundResource(
            if (isOk) {
                R.drawable.status_indicator_green
            } else {
                R.drawable.status_indicator_red
            },
        )
    }

    private fun updateChecklistPending(indicator: View) {
        indicator.setBackgroundResource(R.drawable.status_indicator_pending)
    }


    private companion object {
        const val DIRECT_PIXEL_MIN_SCALE = 0.97f
        const val DEFAULT_BACKGROUND_DISCONNECT_SECS = 60
        const val LATENCY_PING_INTERVAL_MS = 2_000L
        const val CHECKLIST_INTERVAL_MS = 10_000L
        const val LAB_SURFACE_CAPTURE_DELAY_MS = 250L
        const val LAB_SURFACE_CAPTURE_RETRY_DELAY_MS = 150L
        const val LAB_SURFACE_CAPTURE_RETRY_LIMIT = 12
    }

    /** Apply a host-issued brightness only for the current Streaming owner. */
    private fun applyBacklight(generation: Long, value: Int) {
        brightnessOwnership.apply(generation, value)
    }
}
