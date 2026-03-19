package com.displaybridge.client

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.*
import androidx.appcompat.app.AppCompatActivity

/**
 * Settings screen for DisplayBridge.
 *
 * Allows the user to configure host, port, codec,
 * and optional resolution override before connecting.
 * All settings are persisted via SharedPreferences.
 */
class ConnectionActivity : AppCompatActivity() {

    companion object {
        private const val PREFS_NAME = "displaybridge_settings"
        private const val KEY_HOST = "host"
        private const val KEY_PORT = "port"
        private const val KEY_CODEC = "codec"
        private const val KEY_FPS = "overrideFps"
        private const val KEY_OVERRIDE_RES = "overrideResolution"
        private const val KEY_WIDTH = "overrideWidth"
        private const val KEY_HEIGHT = "overrideHeight"
        private const val ACTION_USB_PERMISSION = "com.displaybridge.client.USB_PERMISSION"
    }

    private lateinit var hostInput: EditText
    private lateinit var portInput: EditText
    private lateinit var codecHevc: RadioButton
    private lateinit var codecH264: RadioButton
    private lateinit var fpsSpinner: Spinner
    private lateinit var overrideCheckbox: CheckBox
    private lateinit var widthInput: EditText
    private lateinit var heightInput: EditText
    private lateinit var statusText: TextView
    private lateinit var usbConnectBtn: Button

    private val usbPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == ACTION_USB_PERMISSION) {
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                @Suppress("DEPRECATION")
                val accessory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                } else {
                    intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                }
                if (granted && accessory != null) {
                    launchUSBStreaming(accessory)
                } else {
                    statusText.text = "Status: USB permission denied"
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        val root = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor("#1A1A2E"))
        }

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(40), dp(24), dp(24))
        }

        // Title
        content.addView(TextView(this).apply {
            text = "DisplayBridge"
            setTextColor(Color.WHITE)
            textSize = 28f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }, lp(MATCH_PARENT, WRAP_CONTENT).apply {
            bottomMargin = dp(32)
        })

        // --- Connection Section ---
        content.addView(sectionHeader("Connection"))

        content.addView(label("Host"))
        hostInput = editText(InputType.TYPE_CLASS_TEXT).apply {
            setText(prefs.getString(KEY_HOST, "127.0.0.1"))
        }
        content.addView(hostInput)

        content.addView(label("Port"))
        portInput = editText(InputType.TYPE_CLASS_NUMBER).apply {
            setText(prefs.getInt(KEY_PORT, 7878).toString())
        }
        content.addView(portInput)

        // --- Video Section ---
        content.addView(sectionHeader("Video").apply { topMargin(dp(20)) })

        content.addView(label("Codec"))
        val codecGroup = RadioGroup(this).apply {
            orientation = RadioGroup.HORIZONTAL
        }
        codecHevc = radioButton("HEVC")
        codecH264 = radioButton("H.264")
        codecGroup.addView(codecHevc)
        codecGroup.addView(codecH264)
        val savedCodec = prefs.getString(KEY_CODEC, "hevc")
        if (savedCodec == "h264") codecH264.isChecked = true else codecHevc.isChecked = true
        content.addView(codecGroup, lp(MATCH_PARENT, WRAP_CONTENT).apply { bottomMargin = dp(8) })

        content.addView(label("Frame Rate"))
        val fpsOptions = arrayOf("Auto", "30", "60", "120")
        val fpsValues = intArrayOf(0, 30, 60, 120)
        fpsSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@ConnectionActivity, android.R.layout.simple_spinner_dropdown_item, fpsOptions).apply {
                setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
            }
            setBackgroundColor(Color.parseColor("#2A2A4A"))
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
        val savedFps = prefs.getInt(KEY_FPS, 0)
        fpsSpinner.setSelection(fpsValues.indexOf(savedFps).coerceAtLeast(0))
        content.addView(fpsSpinner, lp(MATCH_PARENT, WRAP_CONTENT).apply { bottomMargin = dp(8) })

        // --- Display Section ---
        content.addView(sectionHeader("Display").apply { topMargin(dp(20)) })

        overrideCheckbox = CheckBox(this).apply {
            text = "Override resolution"
            setTextColor(Color.parseColor("#B0B0CC"))
            isChecked = prefs.getBoolean(KEY_OVERRIDE_RES, false)
        }
        content.addView(overrideCheckbox, lp(MATCH_PARENT, WRAP_CONTENT))

        val resLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        widthInput = editText(InputType.TYPE_CLASS_NUMBER).apply {
            hint = "Width"
            setText(if (prefs.getInt(KEY_WIDTH, 0) > 0) prefs.getInt(KEY_WIDTH, 0).toString() else "")
        }
        heightInput = editText(InputType.TYPE_CLASS_NUMBER).apply {
            hint = "Height"
            setText(if (prefs.getInt(KEY_HEIGHT, 0) > 0) prefs.getInt(KEY_HEIGHT, 0).toString() else "")
        }
        resLayout.addView(widthInput, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { rightMargin = dp(8) })
        resLayout.addView(heightInput, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        content.addView(resLayout, lp(MATCH_PARENT, WRAP_CONTENT).apply { bottomMargin = dp(8) })

        // Enable/disable resolution fields based on checkbox
        fun updateResFields() {
            val enabled = overrideCheckbox.isChecked
            widthInput.isEnabled = enabled
            heightInput.isEnabled = enabled
            widthInput.alpha = if (enabled) 1f else 0.4f
            heightInput.alpha = if (enabled) 1f else 0.4f
        }
        overrideCheckbox.setOnCheckedChangeListener { _, _ -> updateResFields() }
        updateResFields()

        // --- Connect Button (Network/TCP) ---
        val connectBtn = Button(this).apply {
            text = "CONNECT (Network)"
            setTextColor(Color.WHITE)
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setBackgroundColor(Color.parseColor("#4A90D9"))
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }
        content.addView(connectBtn, lp(MATCH_PARENT, WRAP_CONTENT).apply {
            topMargin = dp(24)
        })

        // --- USB Connect Button ---
        usbConnectBtn = Button(this).apply {
            text = "CONNECT (USB)"
            setTextColor(Color.WHITE)
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setBackgroundColor(Color.parseColor("#2ECC71"))
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }
        content.addView(usbConnectBtn, lp(MATCH_PARENT, WRAP_CONTENT).apply {
            topMargin = dp(12)
        })

        usbConnectBtn.setOnClickListener {
            saveSettings()
            attemptUSBConnect()
        }

        // --- Status ---
        statusText = TextView(this).apply {
            text = "Status: Disconnected"
            setTextColor(Color.parseColor("#808099"))
            textSize = 14f
            gravity = Gravity.CENTER
        }
        content.addView(statusText, lp(MATCH_PARENT, WRAP_CONTENT).apply {
            topMargin = dp(16)
        })

        root.addView(content, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        setContentView(root)

        // Connect button handler
        connectBtn.setOnClickListener {
            saveSettings()
            launchStreaming()
        }

        // Register USB permission receiver
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbPermissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(usbPermissionReceiver, filter)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(usbPermissionReceiver)
        } catch (_: Exception) {}
    }

    private fun attemptUSBConnect() {
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val accessoryList = usbManager.accessoryList

        if (accessoryList.isNullOrEmpty()) {
            statusText.text = "Status: No USB accessory found.\nMake sure the server is running and USB cable is connected."
            return
        }

        val accessory = accessoryList[0]
        statusText.text = "Status: USB accessory found: ${accessory.manufacturer} ${accessory.model}"

        if (usbManager.hasPermission(accessory)) {
            launchUSBStreaming(accessory)
        } else {
            statusText.text = "Status: Requesting USB permission..."
            val permissionIntent = PendingIntent.getBroadcast(
                this, 0, Intent(ACTION_USB_PERMISSION),
                PendingIntent.FLAG_MUTABLE
            )
            usbManager.requestPermission(accessory, permissionIntent)
        }
    }

    private fun launchUSBStreaming(accessory: UsbAccessory) {
        statusText.text = "Status: Connecting via USB..."

        val intent = Intent(this, DisplayBridgeActivity::class.java).apply {
            action = UsbManager.ACTION_USB_ACCESSORY_ATTACHED
            putExtra(UsbManager.EXTRA_ACCESSORY, accessory)
        }
        startActivity(intent)
    }

    private fun saveSettings() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
        prefs.putString(KEY_HOST, hostInput.text.toString().ifBlank { "127.0.0.1" })
        prefs.putInt(KEY_PORT, portInput.text.toString().toIntOrNull() ?: 7878)
        prefs.putString(KEY_CODEC, if (codecH264.isChecked) "h264" else "hevc")
        val fpsValues = intArrayOf(0, 30, 60, 120)
        prefs.putInt(KEY_FPS, fpsValues.getOrElse(fpsSpinner.selectedItemPosition) { 0 })
        prefs.putBoolean(KEY_OVERRIDE_RES, overrideCheckbox.isChecked)
        prefs.putInt(KEY_WIDTH, widthInput.text.toString().toIntOrNull() ?: 0)
        prefs.putInt(KEY_HEIGHT, heightInput.text.toString().toIntOrNull() ?: 0)
        prefs.apply()
    }

    private fun launchStreaming() {
        statusText.text = "Status: Connecting..."

        val host = hostInput.text.toString().ifBlank { "127.0.0.1" }
        val port = portInput.text.toString().toIntOrNull() ?: 7878
        val codec = if (codecH264.isChecked) "h264" else "hevc"
        val fpsValues = intArrayOf(0, 30, 60, 120)
        val overrideFps = fpsValues.getOrElse(fpsSpinner.selectedItemPosition) { 0 }
        val overrideWidth = if (overrideCheckbox.isChecked) (widthInput.text.toString().toIntOrNull() ?: 0) else 0
        val overrideHeight = if (overrideCheckbox.isChecked) (heightInput.text.toString().toIntOrNull() ?: 0) else 0

        val intent = Intent(this, DisplayBridgeActivity::class.java).apply {
            putExtra("host", host)
            putExtra("port", port)
            putExtra("codec", codec)
            putExtra("overrideFps", overrideFps)
            putExtra("overrideWidth", overrideWidth)
            putExtra("overrideHeight", overrideHeight)
        }
        startActivity(intent)
    }

    override fun onResume() {
        super.onResume()
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val lastCrash = prefs.getString("last_crash", null)
        if (lastCrash != null) {
            statusText.text = "CRASH: $lastCrash"
            statusText.setTextColor(Color.parseColor("#FF4444"))
            prefs.edit().remove("last_crash").apply()
        } else {
            statusText.text = "Status: Disconnected"
            statusText.setTextColor(Color.parseColor("#808099"))
        }
    }

    // --- UI Helpers ---

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun lp(width: Int, height: Int): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(width, height)

    private fun sectionHeader(title: String): TextView = TextView(this).apply {
        text = title
        setTextColor(Color.parseColor("#7070AA"))
        textSize = 13f
        typeface = Typeface.DEFAULT_BOLD
        letterSpacing = 0.1f
        setPadding(0, dp(8), 0, dp(8))
    }

    private fun label(text: String): TextView = TextView(this).apply {
        this.text = text
        setTextColor(Color.parseColor("#C0C0DD"))
        textSize = 15f
        setPadding(0, dp(4), 0, dp(4))
    }

    private fun editText(inputType: Int): EditText = EditText(this).apply {
        this.inputType = inputType
        setTextColor(Color.WHITE)
        setHintTextColor(Color.parseColor("#505070"))
        setBackgroundColor(Color.parseColor("#2A2A4A"))
        setPadding(dp(12), dp(12), dp(12), dp(12))
    }

    private fun radioButton(text: String): RadioButton = RadioButton(this).apply {
        this.text = text
        setTextColor(Color.parseColor("#C0C0DD"))
        buttonTintList = android.content.res.ColorStateList.valueOf(Color.parseColor("#4A90D9"))
    }

    private fun View.topMargin(px: Int) {
        val params = layoutParams as? LinearLayout.LayoutParams
        params?.topMargin = px
    }
}
