package com.displaybridge.client

import android.content.Context
import android.content.res.Configuration
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.displaybridge.client.decoder.HardwareDecoder
import com.displaybridge.client.model.DeviceConfig
import com.displaybridge.client.render.DisplayRenderer
import com.displaybridge.client.render.DisplaySurfaceView
import com.displaybridge.client.transport.Transport
import com.displaybridge.client.transport.USBAccessoryTransport
import com.displaybridge.client.transport.USBSocketTransport

/**
 * Main activity for the DisplayBridge client.
 *
 * Sets up fullscreen immersive mode, creates the rendering surface,
 * and orchestrates the client session lifecycle.
 */
class DisplayBridgeActivity : AppCompatActivity(), ClientSession.SessionListener {

    companion object {
        private const val TAG = "DisplayBridgeActivity"
    }

    private var session: ClientSession? = null
    private var surfaceView: DisplaySurfaceView? = null
    private var container: FrameLayout? = null
    private var currentConfig: DeviceConfig? = null
    private var debugOverlay: android.widget.TextView? = null
    private var debugHandler: android.os.Handler? = null

    // Settings from intent extras (set by ConnectionActivity)
    private var settingsHost = "127.0.0.1"
    private var settingsPort = 7878
    private var settingsCodec = "hevc"
    private var settingsColorSpace = "srgb"
    private var settingsOverrideWidth = 0
    private var settingsOverrideHeight = 0

    private lateinit var transport: Transport
    private val decoder = HardwareDecoder()
    private val renderer = DisplayRenderer()
    private var isUSBAccessory = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Set uncaught exception handler to log crashes
        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            Log.e(TAG, "CRASH in thread ${thread.name}: ${throwable.message}", throwable)
            // Write to shared prefs so ConnectionActivity can show it
            try {
                getSharedPreferences("displaybridge_settings", Context.MODE_PRIVATE)
                    .edit()
                    .putString("last_crash", "${throwable.javaClass.simpleName}: ${throwable.message}\n${throwable.stackTraceToString().take(500)}")
                    .apply()
            } catch (_: Exception) {}
            defaultHandler?.uncaughtException(thread, throwable)
        }

        // Determine launch mode: USB Accessory vs Network/TCP
        val accessory = getUSBAccessory()

        if (accessory != null) {
            // Launched by USB_ACCESSORY_ATTACHED — use USB Accessory transport
            isUSBAccessory = true
            Log.i(TAG, "Launched via USB Accessory: ${accessory.manufacturer} ${accessory.model}")

            // Check permission
            val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
            if (!usbManager.hasPermission(accessory)) {
                Log.e(TAG, "No USB permission for accessory, finishing")
                Toast.makeText(this, "USB permission denied", Toast.LENGTH_SHORT).show()
                finish()
                return
            }

            // Load codec/colorSpace from SharedPreferences (port/host not needed for USB)
            val prefs = getSharedPreferences("displaybridge_settings", Context.MODE_PRIVATE)
            settingsCodec = prefs.getString("codec", "hevc") ?: "hevc"
            settingsColorSpace = prefs.getString("colorSpace", "srgb") ?: "srgb"
            settingsOverrideWidth = prefs.getInt("overrideWidth", 0)
            settingsOverrideHeight = prefs.getInt("overrideHeight", 0)
            if (!prefs.getBoolean("overrideResolution", false)) {
                settingsOverrideWidth = 0
                settingsOverrideHeight = 0
            }

            transport = USBAccessoryTransport(this, accessory)
        } else {
            // Launched by ConnectionActivity — use TCP socket transport
            settingsHost = intent.getStringExtra("host") ?: "127.0.0.1"
            settingsPort = intent.getIntExtra("port", 7878)
            settingsCodec = intent.getStringExtra("codec") ?: "hevc"
            settingsColorSpace = intent.getStringExtra("colorSpace") ?: "srgb"
            settingsOverrideWidth = intent.getIntExtra("overrideWidth", 0)
            settingsOverrideHeight = intent.getIntExtra("overrideHeight", 0)

            transport = USBSocketTransport(settingsHost, settingsPort)
        }

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Create the container layout
        val frameLayout = FrameLayout(this)
        frameLayout.setBackgroundColor(android.graphics.Color.BLACK)
        container = frameLayout
        setContentView(frameLayout)

        // Enter fullscreen immersive mode (must be after setContentView)
        enterImmersiveMode()

        setupSession()

        // USB debug overlay — shows transport status on screen
        if (isUSBAccessory) {
            val tv = android.widget.TextView(this).apply {
                setTextColor(android.graphics.Color.YELLOW)
                textSize = 14f
                setBackgroundColor(android.graphics.Color.argb(128, 0, 0, 0))
                setPadding(16, 8, 16, 8)
            }
            frameLayout.addView(tv, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            ).apply { gravity = android.view.Gravity.TOP or android.view.Gravity.START })
            debugOverlay = tv

            val handler = android.os.Handler(mainLooper)
            debugHandler = handler
            val updateRunnable = object : Runnable {
                override fun run() {
                    val usbT = transport as? USBAccessoryTransport
                    tv.text = "USB: ${usbT?.debugStatus ?: "?"} | pkts=${usbT?.debugPacketCount} bytes=${usbT?.debugByteCount}"
                    handler.postDelayed(this, 500)
                }
            }
            handler.postDelayed(updateRunnable, 500)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)

        val newDeviceConfig = buildDeviceConfig()
        val old = currentConfig
        if (old != null && old.width == newDeviceConfig.width && old.height == newDeviceConfig.height) {
            return // No resolution change
        }

        Log.i(TAG, "Orientation changed: ${newDeviceConfig.width}x${newDeviceConfig.height}")
        currentConfig = newDeviceConfig
        enterImmersiveMode()

        // Send CONFIG_UPDATE to server (no disconnect/reconnect)
        session?.sendConfigUpdate(newDeviceConfig)

        // IMPORTANT: Set no-op listener BEFORE removing old views.
        // Otherwise surfaceDestroyed fires the old listener which calls session.stop()
        renderer.setSurfaceStateListener(null)

        // Recreate surface view for new aspect ratio + reconfigure decoder
        val frameLayout = container ?: return
        frameLayout.removeAllViews()

        val view = DisplaySurfaceView(this, renderer, newDeviceConfig)
        frameLayout.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ).apply {
                gravity = android.view.Gravity.CENTER
            }
        )
        surfaceView = view

        // When new surface is ready, reconfigure decoder
        renderer.setSurfaceStateListener(object : DisplayRenderer.SurfaceStateListener {
            override fun onSurfaceReady(surface: Surface) {
                Log.i(TAG, "New surface ready after orientation change, reconfiguring decoder")
                decoder.configure(newDeviceConfig.width, newDeviceConfig.height, surface)
            }

            override fun onSurfaceDestroyed() {
                Log.i(TAG, "Surface destroyed")
            }
        })
    }

    private fun setupSession() {
        val config = buildDeviceConfig()
        currentConfig = config
        Log.i(TAG, "Device config: ${config.width}x${config.height}@${config.refreshRate}Hz")

        val frameLayout = container ?: return

        // Remove old surface view
        frameLayout.removeAllViews()

        // Create the surface view
        val view = DisplaySurfaceView(this, renderer, config)
        frameLayout.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ).apply {
                gravity = android.view.Gravity.CENTER
            }
        )
        surfaceView = view

        // Create session
        val clientSession = ClientSession(
            config = config,
            transport = transport,
            decoder = decoder,
            renderer = renderer
        )
        clientSession.setSessionListener(this)
        session = clientSession

        // Start session when surface is ready
        renderer.setSurfaceStateListener(object : DisplayRenderer.SurfaceStateListener {
            override fun onSurfaceReady(surface: Surface) {
                Log.i(TAG, "Surface ready, starting session")
                clientSession.start(surface)
            }

            override fun onSurfaceDestroyed() {
                Log.i(TAG, "Surface destroyed, stopping session")
                clientSession.stop()
            }
        })
    }

    /**
     * Builds the DeviceConfig based on the device's screen properties.
     */
    private fun buildDeviceConfig(): DeviceConfig {
        val metrics = DisplayMetrics()

        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(metrics)

        val width = if (settingsOverrideWidth > 0) settingsOverrideWidth else metrics.widthPixels
        val height = if (settingsOverrideHeight > 0) settingsOverrideHeight else metrics.heightPixels

        @Suppress("DEPRECATION")
        val refreshRate = windowManager.defaultDisplay.refreshRate.toInt()

        return DeviceConfig(
            width = width,
            height = height,
            refreshRate = refreshRate,
            codec = settingsCodec,
            colorSpace = settingsColorSpace,
            deviceName = Build.MODEL
        )
    }

    /**
     * Enters fullscreen immersive mode, hiding system bars.
     */
    private fun enterImmersiveMode() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.systemBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                )
        }
    }

    /**
     * Extracts the UsbAccessory from the intent or UsbManager.
     * Falls back to UsbManager.getAccessoryList() if intent extra is missing
     * (common on Samsung devices).
     */
    @Suppress("DEPRECATION")
    private fun getUSBAccessory(): UsbAccessory? {
        // First try: get from intent extra
        val fromIntent = if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
            } else {
                intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
            }
        } else null

        if (fromIntent != null) return fromIntent

        // Fallback: get from UsbManager directly (more reliable on some devices)
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val list = usbManager.accessoryList
        if (!list.isNullOrEmpty()) {
            Log.i(TAG, "Got accessory from UsbManager.accessoryList fallback")
            return list[0]
        }

        return null
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            enterImmersiveMode()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "Activity destroyed, cleaning up")
        session?.stop()
        session = null
    }

    // -- ClientSession.SessionListener --

    override fun onConnected() {
        runOnUiThread {
            Log.i(TAG, "Connected to server")
            Toast.makeText(this, "Connected to DisplayBridge server", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onDisconnected(reason: String) {
        runOnUiThread {
            Log.i(TAG, "Disconnected: $reason")
            Toast.makeText(this, "Disconnected: $reason", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    override fun onError(message: String) {
        runOnUiThread {
            Log.e(TAG, "Error: $message")
            Toast.makeText(this, "Error: $message", Toast.LENGTH_LONG).show()
        }
    }
}
