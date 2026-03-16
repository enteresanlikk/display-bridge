package com.displaybridge.client.transport

import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import com.displaybridge.client.protocol.PacketFramer
import java.io.BufferedInputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Transport over USB Accessory (AOA) protocol.
 *
 * The macOS server initiates AOA mode via USB control transfers.
 * Android sees the server as a USB accessory and communicates
 * via a file descriptor — no adb required.
 */
class USBAccessoryTransport(
    private val context: Context,
    private val accessory: UsbAccessory
) : Transport {

    companion object {
        private const val TAG = "USBAccessoryTransport"
        private const val MAX_PAYLOAD_SIZE = 8 * 1024 * 1024 // 8MB max per packet
        private val MAGIC = byteArrayOf(0x44, 0x42, 0x52, 0x47) // "DBRG"
    }

    private var fileDescriptor: ParcelFileDescriptor? = null
    private var inputStream: InputStream? = null
    private var rawInputStream: FileInputStream? = null
    private var outputStream: FileOutputStream? = null
    private var receiveThread: Thread? = null

    @Volatile
    private var connected = false

    /** Debug counters visible to the activity */
    @Volatile var debugPacketCount = 0; private set
    @Volatile var debugByteCount = 0L; private set
    @Volatile var debugStatus = "idle"; private set

    override fun connect() {
        if (connected) {
            Log.w(TAG, "Already connected")
            return
        }

        val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        val fd = usbManager.openAccessory(accessory)
            ?: throw IOException("Failed to open USB accessory")

        fileDescriptor = fd
        val rawIn = FileInputStream(fd.fileDescriptor)
        rawInputStream = rawIn
        // Wrap in BufferedInputStream with 256KB buffer — ensures partial USB
        // transfers are properly accumulated and not lost on small reads
        inputStream = BufferedInputStream(rawIn, 262144)
        outputStream = FileOutputStream(fd.fileDescriptor)
        connected = true

        Log.i(TAG, "USB Accessory connected: ${accessory.manufacturer} ${accessory.model}")
    }

    override fun send(data: ByteArray) {
        val out = outputStream ?: throw IOException("Not connected")
        synchronized(out) {
            out.write(data)
            out.flush()
        }
    }

    override fun receiveLoop(callback: (ByteArray) -> Unit, onComplete: (() -> Unit)?) {
        receiveThread = Thread({
            val input = inputStream ?: return@Thread
            Log.i(TAG, "Receive loop started (USB Accessory, BufferedInputStream 256KB)")

            try {
                debugStatus = "waiting for first packet..."

                while (connected && !Thread.currentThread().isInterrupted) {
                    // Read 28-byte header
                    Log.d(TAG, "Waiting for header (28 bytes)...")
                    val header = readExact(input, PacketFramer.HEADER_SIZE) ?: break
                    Log.d(TAG, "Got header: magic=${header[0].toInt() and 0xFF},${header[1].toInt() and 0xFF},${header[2].toInt() and 0xFF},${header[3].toInt() and 0xFF}")

                    // Validate magic bytes "DBRG"
                    if (header[0] != 0x44.toByte() || header[1] != 0x42.toByte() ||
                        header[2] != 0x52.toByte() || header[3] != 0x47.toByte()) {
                        Log.w(TAG, "Bad magic, re-syncing...")
                        syncToMagic(input)
                        continue
                    }

                    // Extract payload length from header bytes [24..27] (UInt32 LE)
                    val lengthBuffer = ByteBuffer.wrap(header, 24, 4)
                    lengthBuffer.order(ByteOrder.LITTLE_ENDIAN)
                    val payloadLength = lengthBuffer.getInt() and 0x7FFFFFFF // treat as unsigned

                    if (payloadLength > MAX_PAYLOAD_SIZE) {
                        Log.e(TAG, "Payload too large: $payloadLength, re-syncing...")
                        syncToMagic(input)
                        continue
                    }

                    // Read payload
                    val payload = if (payloadLength > 0) {
                        readExact(input, payloadLength) ?: break
                    } else {
                        ByteArray(0)
                    }

                    // Combine header + payload
                    val fullPacket = ByteArray(PacketFramer.HEADER_SIZE + payloadLength)
                    System.arraycopy(header, 0, fullPacket, 0, PacketFramer.HEADER_SIZE)
                    if (payloadLength > 0) {
                        System.arraycopy(payload, 0, fullPacket, PacketFramer.HEADER_SIZE, payloadLength)
                    }

                    debugPacketCount++
                    debugByteCount += fullPacket.size.toLong()
                    debugStatus = "pkts=$debugPacketCount bytes=$debugByteCount"
                    callback(fullPacket)
                }
            } catch (e: IOException) {
                if (connected) {
                    Log.e(TAG, "Receive loop error: ${e.message}")
                    debugStatus = "ERROR: ${e.message}"
                }
            } catch (e: OutOfMemoryError) {
                debugStatus = "OOM ERROR"
                Log.e(TAG, "OOM in receive loop")
            } finally {
                Log.i(TAG, "Receive loop ended")
                debugStatus = "loop ended (pkts=$debugPacketCount)"
                onComplete?.invoke()
            }
        }, "DisplayBridge-USB-Receive")

        receiveThread?.isDaemon = true
        receiveThread?.start()
    }

    private fun readExact(input: InputStream, count: Int): ByteArray? {
        val buffer = ByteArray(count)
        var offset = 0
        var zeroReadCount = 0
        while (offset < count) {
            val bytesRead = input.read(buffer, offset, count - offset)
            if (bytesRead == -1) {
                Log.w(TAG, "Stream ended while reading (got $offset of $count bytes)")
                return null
            }
            if (bytesRead == 0) {
                zeroReadCount++
                if (zeroReadCount > 100) {
                    Log.e(TAG, "Too many zero-byte reads (got $offset of $count bytes), aborting")
                    return null
                }
                Thread.sleep(1) // prevent tight spin
                continue
            }
            zeroReadCount = 0
            offset += bytesRead
        }
        return buffer
    }

    /**
     * Scans the input stream byte-by-byte until "DBRG" magic is found.
     * When found, reads the rest of that header, skips its payload,
     * so the caller can read the NEXT packet cleanly.
     */
    private fun syncToMagic(input: InputStream) {
        Log.i(TAG, "Scanning for DBRG magic...")
        var matched = 0
        var bytesScanned = 0
        while (connected) {
            val b = input.read()
            if (b == -1) return
            bytesScanned++
            if (b.toByte() == MAGIC[matched]) {
                matched++
                if (matched == 4) {
                    Log.i(TAG, "Found DBRG magic after scanning $bytesScanned bytes")
                    // Read remaining 24 bytes of this header
                    val restHeader = readExact(input, PacketFramer.HEADER_SIZE - 4) ?: return
                    // Parse payload length and skip payload
                    val lenBuf = ByteBuffer.wrap(restHeader, 20, 4) // offset 24-4=20 in restHeader
                    lenBuf.order(ByteOrder.LITTLE_ENDIAN)
                    val payloadLen = lenBuf.getInt() and 0x7FFFFFFF
                    if (payloadLen in 1..MAX_PAYLOAD_SIZE) {
                        readExact(input, payloadLen) // skip payload
                    }
                    return
                }
            } else {
                matched = if (b.toByte() == MAGIC[0]) 1 else 0
            }
        }
    }

    override fun disconnect() {
        connected = false
        Log.i(TAG, "Disconnecting USB Accessory...")

        receiveThread?.interrupt()
        receiveThread = null

        try { outputStream?.close() } catch (_: IOException) {}
        try { inputStream?.close() } catch (_: IOException) {}
        try { rawInputStream?.close() } catch (_: IOException) {}
        try { fileDescriptor?.close() } catch (_: IOException) {}

        outputStream = null
        inputStream = null
        rawInputStream = null
        fileDescriptor = null

        Log.i(TAG, "USB Accessory disconnected")
    }

    override fun isConnected(): Boolean = connected
}
