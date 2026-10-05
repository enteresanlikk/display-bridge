package com.displaybridge.client

import android.util.Log
import android.view.Surface
import com.displaybridge.client.decoder.HardwareDecoder
import com.displaybridge.client.model.DeviceConfig
import com.displaybridge.client.protocol.PacketFramer
import com.displaybridge.client.protocol.PacketType
import com.displaybridge.client.render.DisplayRenderer
import com.displaybridge.client.transport.Transport
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Orchestrates the DisplayBridge client session.
 *
 * Manages the full lifecycle: connection, handshake, video streaming,
 * input forwarding, and cleanup.
 */
class ClientSession(
    private val config: DeviceConfig,
    private val transport: Transport,
    private val decoder: HardwareDecoder,
    private val renderer: DisplayRenderer
) {

    companion object {
        private const val TAG = "ClientSession"
    }

    @Volatile
    private var isRunning = false

    @Volatile
    private var decoderReady = false

    private var connectThread: Thread? = null

    // Touch events arrive on the UI thread, which must never do socket/USB I/O.
    // One thread keeps them in order.
    @Volatile
    private var inputExecutor: ExecutorService? = null
    private var surface: Surface? = null

    /**
     * Listener for session lifecycle events.
     */
    interface SessionListener {
        fun onConnected()
        fun onDisconnected(reason: String)
        fun onError(message: String)
    }

    private var listener: SessionListener? = null

    fun setSessionListener(listener: SessionListener?) {
        this.listener = listener
    }

    /**
     * Starts the session: connects to the server, sends handshake,
     * and immediately starts the receive loop.
     *
     * Decoder is configured lazily when HANDSHAKE_ACK arrives,
     * so the USB endpoint is always being drained.
     */
    fun start(surface: Surface) {
        if (isRunning) {
            Log.w(TAG, "Session already running")
            return
        }

        isRunning = true
        this.surface = surface
        inputExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "DisplayBridge-Input").apply { isDaemon = true }
        }

        connectThread = Thread({
            try {
                // Step 1: Connect transport
                Log.i(TAG, "Connecting to server...")
                transport.connect()

                // Step 2: Send handshake
                Log.i(TAG, "Sending handshake...")
                val handshakePacket = PacketFramer.createHandshakeRequest(config)
                transport.send(handshakePacket)

                // Step 3: Start receive loop IMMEDIATELY
                // Decoder will be configured when HANDSHAKE_ACK arrives.
                // This ensures the USB endpoint buffer is always being drained,
                // preventing WritePipe timeouts on the server.
                Log.i(TAG, "Starting receive loop...")
                listener?.onConnected()
                startStreaming()

            } catch (e: Exception) {
                Log.e(TAG, "Failed to start session: ${e.message}", e)
                listener?.onError("Connection failed: ${e.message}")
                stop()
            }
        }, "DisplayBridge-Connect")

        connectThread?.isDaemon = true
        connectThread?.start()
    }

    /**
     * Starts the receive loop, processing incoming packets from the server.
     */
    private fun startStreaming() {
        transport.receiveLoop({ packetData ->
            if (!isRunning) return@receiveLoop

            try {
                val packet = PacketFramer.parsePacket(packetData)
                handlePacket(packet)
            } catch (e: Exception) {
                Log.e(TAG, "Error processing packet: ${e.message}")
            }
        }) {
            // Receive loop ended — server disconnected or connection lost
            Log.i(TAG, "Receive loop ended — server disconnected")
            if (isRunning) {
                stop()
            }
        }
    }

    /**
     * Handles a parsed packet based on its type.
     */
    private fun handlePacket(packet: PacketFramer.ParsedPacket) {
        when (packet.type) {
            PacketType.HANDSHAKE_ACK -> {
                Log.i(TAG, "Handshake ACK — configuring decoder ${config.width}x${config.height}")
                if (packet.payload.isNotEmpty()) {
                    val ackJson = String(packet.payload, Charsets.UTF_8)
                    Log.d(TAG, "Handshake ACK payload: $ackJson")
                }
                // Configure decoder NOW — the receive loop is already running
                // so the USB buffer stays drained while MediaCodec initializes
                val s = surface
                if (s != null) {
                    decoder.configure(config.width, config.height, s, config.codec)
                    decoderReady = true
                    Log.i(TAG, "Decoder configured and ready")
                } else {
                    Log.e(TAG, "No surface available for decoder configuration!")
                }
            }

            PacketType.VIDEO_FRAME -> {
                if (!decoderReady) {
                    // Decoder not ready yet — drop frame silently
                    return
                }
                val (isKeyFrame, nalData) = PacketFramer.parseVideoFrame(packet.payload)
                decoder.decodeSample(nalData, isKeyFrame, packet.timestamp)
            }

            PacketType.PING -> {
                // PONG is handled at the transport level for USB to avoid
                // delays from video decoding blocking the receive thread.
                // For TCP transport, respond here as fallback.
                val pong = PacketFramer.createPong(packet.sequenceNumber, packet.timestamp)
                try {
                    transport.send(pong)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send PONG: ${e.message}")
                }
            }

            PacketType.CONFIG_UPDATE -> {
                Log.i(TAG, "Config update received")
                if (packet.payload.isNotEmpty()) {
                    val configJson = String(packet.payload, Charsets.UTF_8)
                    Log.d(TAG, "Config update: $configJson")
                }
            }

            PacketType.DISCONNECT -> {
                Log.i(TAG, "Server disconnected gracefully")
                stop()
            }

            PacketType.ERROR -> {
                val errorMsg = if (packet.payload.isNotEmpty()) {
                    String(packet.payload, Charsets.UTF_8)
                } else {
                    "Unknown server error"
                }
                Log.e(TAG, "Server error: $errorMsg")
                listener?.onError(errorMsg)
                stop()
            }

            else -> {
                Log.w(TAG, "Unhandled packet type: ${packet.type}")
            }
        }
    }

    /**
     * Sends a config update to the server (e.g., on orientation change).
     */
    fun sendConfigUpdate(newConfig: DeviceConfig) {
        if (!isRunning || !transport.isConnected()) return

        Thread({
            try {
                val packet = PacketFramer.createConfigUpdate(newConfig)
                transport.send(packet)
                Log.i(TAG, "Sent CONFIG_UPDATE: ${newConfig.width}x${newConfig.height}")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send config update: ${e.message}")
            }
        }, "DisplayBridge-ConfigUpdate").start()
    }

    /**
     * Sends a pointer event (touch / pen / mouse) to the server. Dropped until the
     * handshake completes, since the server ignores input before it is streaming.
     * See [PacketFramer.createInputEvent] for the units.
     */
    fun sendInput(kind: Int, button: Int, x: Float, y: Float, dx: Float, dy: Float, pressure: Float) {
        if (!isRunning || !decoderReady) return
        val packet = PacketFramer.createInputEvent(kind, button, x, y, dx, dy, pressure)
        try {
            inputExecutor?.execute {
                try {
                    transport.send(packet)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send input: ${e.message}")
                }
            }
        } catch (_: RejectedExecutionException) {
            // Session stopped between the check above and here.
        }
    }

    /**
     * Stops the session and releases all resources.
     */
    fun stop() {
        if (!isRunning) return

        Log.i(TAG, "Stopping session...")
        isRunning = false
        decoderReady = false
        inputExecutor?.shutdownNow()
        inputExecutor = null

        // Say goodbye before closing. Over USB the source cannot see us leave: it keeps
        // streaming into a dead pipe for seconds, and a reconnect inside that window
        // joins a session that will never send a handshake ack (black screen). Sent off
        // this thread (it may be the UI thread) and bounded, so a stuck write can't
        // keep the transport open.
        val goodbye = PacketFramer.createPacket(
            PacketType.DISCONNECT, 0, System.nanoTime() / 1000, ByteArray(0)
        )
        val sender = Thread({
            try {
                transport.send(goodbye)
            } catch (_: Exception) {
            }
        }, "DisplayBridge-Goodbye")
        sender.start()
        try {
            sender.join(150)
        } catch (_: InterruptedException) {
        }

        transport.disconnect()
        decoder.release()

        connectThread?.interrupt()
        connectThread = null

        listener?.onDisconnected("Session stopped")
        Log.i(TAG, "Session stopped")
    }
}
