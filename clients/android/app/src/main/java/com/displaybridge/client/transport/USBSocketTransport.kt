package com.displaybridge.client.transport

import android.util.Log
import com.displaybridge.client.protocol.PacketFramer
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * TCP socket transport connecting to the macOS server via USB.
 *
 * The connection is made to 127.0.0.1:7878, which is forwarded to the
 * macOS server through `adb reverse tcp:7878 tcp:7878`.
 */
class USBSocketTransport(
    private val host: String = "127.0.0.1",
    private val port: Int = 7878
) : Transport {

    companion object {
        private const val TAG = "USBSocketTransport"
        private const val READ_TIMEOUT_MS = 0 // No timeout — blocking reads for streaming
    }

    private var socket: Socket? = null
    private var outputStream: OutputStream? = null
    private var inputStream: InputStream? = null
    private var receiveThread: Thread? = null

    @Volatile
    private var isConnected = false

    /**
     * Opens a TCP socket connection to the server.
     *
     * @throws IOException if the connection cannot be established.
     */
    override fun connect() {
        if (isConnected) {
            Log.w(TAG, "Already connected")
            return
        }

        Log.i(TAG, "Connecting to $host:$port...")
        val sock = Socket(host, port)
        sock.tcpNoDelay = true // Disable Nagle's algorithm for low latency
        sock.soTimeout = READ_TIMEOUT_MS
        sock.receiveBufferSize = 524288 // 512KB — limit TCP receive buffer to prevent deep buffering

        socket = sock
        outputStream = sock.getOutputStream()
        inputStream = sock.getInputStream()
        isConnected = true

        Log.i(TAG, "Connected to server")
    }

    /**
     * Sends raw bytes to the server.
     * Thread-safe: synchronized on the output stream.
     *
     * @throws IOException if the socket is not connected or write fails.
     */
    override fun send(data: ByteArray) {
        val out = outputStream ?: throw IOException("Not connected")
        synchronized(out) {
            out.write(data)
            out.flush()
        }
    }

    /**
     * Starts a blocking receive loop on a background thread.
     *
     * Reads packets by first reading the 28-byte header to determine payload
     * length, then reading the full payload. Delivers complete packets
     * (header + payload) to the callback.
     *
     * @param callback Called with each complete packet (header + payload bytes).
     */
    override fun receiveLoop(callback: (ByteArray) -> Unit) {
        receiveThread = Thread({
            val input = inputStream ?: return@Thread
            Log.i(TAG, "Receive loop started")

            try {
                while (isConnected && !Thread.currentThread().isInterrupted) {
                    // Read 28-byte header
                    val header = readExact(input, PacketFramer.HEADER_SIZE) ?: break

                    // Extract payload length from header bytes [24..27] (UInt32 LE)
                    val lengthBuffer = ByteBuffer.wrap(header, 24, 4)
                    lengthBuffer.order(ByteOrder.LITTLE_ENDIAN)
                    val payloadLength = lengthBuffer.getInt()

                    if (payloadLength < 0) {
                        Log.e(TAG, "Invalid payload length: $payloadLength")
                        break
                    }

                    // Read payload
                    val payload = if (payloadLength > 0) {
                        readExact(input, payloadLength) ?: break
                    } else {
                        ByteArray(0)
                    }

                    // Combine header + payload into a complete packet
                    val fullPacket = ByteArray(PacketFramer.HEADER_SIZE + payloadLength)
                    System.arraycopy(header, 0, fullPacket, 0, PacketFramer.HEADER_SIZE)
                    if (payloadLength > 0) {
                        System.arraycopy(payload, 0, fullPacket, PacketFramer.HEADER_SIZE, payloadLength)
                    }

                    callback(fullPacket)
                }
            } catch (e: IOException) {
                if (isConnected) {
                    Log.e(TAG, "Receive loop error: ${e.message}")
                }
            } finally {
                Log.i(TAG, "Receive loop ended")
            }
        }, "DisplayBridge-Receive")

        receiveThread?.isDaemon = true
        receiveThread?.start()
    }

    /**
     * Reads exactly [count] bytes from the input stream.
     * Blocks until all bytes are read or the stream ends.
     *
     * @return The byte array of exactly [count] bytes, or null if stream ended prematurely.
     */
    private fun readExact(input: InputStream, count: Int): ByteArray? {
        val buffer = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val bytesRead = input.read(buffer, offset, count - offset)
            if (bytesRead == -1) {
                Log.w(TAG, "Stream ended while reading (got $offset of $count bytes)")
                return null
            }
            offset += bytesRead
        }
        return buffer
    }

    /**
     * Disconnects from the server and cleans up resources.
     */
    override fun disconnect() {
        isConnected = false
        Log.i(TAG, "Disconnecting...")

        receiveThread?.interrupt()
        receiveThread = null

        try {
            outputStream?.close()
        } catch (_: IOException) {}

        try {
            inputStream?.close()
        } catch (_: IOException) {}

        try {
            socket?.close()
        } catch (_: IOException) {}

        outputStream = null
        inputStream = null
        socket = null

        Log.i(TAG, "Disconnected")
    }

    /**
     * Returns whether the transport is currently connected.
     */
    override fun isConnected(): Boolean = isConnected
}
