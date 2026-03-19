package com.displaybridge.client.transport

import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import com.displaybridge.client.protocol.PacketFramer
import com.displaybridge.client.protocol.PacketType
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue

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
        /** Must match f_accessory's BULK_BUFFER_SIZE in the kernel.
         *  Reading exactly this amount ensures we consume full USB transfers
         *  and minimize the gap between acc_read() USB request re-queues. */
        private const val USB_READ_SIZE = 16384
        private val MAGIC = byteArrayOf(0x44, 0x42, 0x52, 0x47) // "DBRG"
    }

    private var fileDescriptor: ParcelFileDescriptor? = null
    private var inputStream: FileInputStream? = null
    private var outputStream: FileOutputStream? = null
    private var receiveThread: Thread? = null
    private var processThread: Thread? = null

    @Volatile
    private var connected = false

    /** Debug counters visible to the activity */
    @Volatile var debugPacketCount = 0; private set
    @Volatile var debugByteCount = 0L; private set
    @Volatile var debugReadCalls = 0; private set
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
        // Use raw FileInputStream directly — BufferedInputStream's internal
        // available()/read() logic returns -1 prematurely on USB file descriptors,
        // killing the receive loop after the first packet.
        // readExact() already handles partial reads with its own accumulation loop.
        inputStream = FileInputStream(fd.fileDescriptor)
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
        // Packet queue decouples USB reading from application processing.
        // The read thread stays fast (drains USB buffer, handles PING/PONG immediately),
        // while the process thread handles video decoding at its own pace.
        val packetQueue = LinkedBlockingQueue<ByteArray>()

        // Process thread — delivers packets to the application callback
        processThread = Thread({
            try {
                while (connected && !Thread.currentThread().isInterrupted) {
                    val packet = packetQueue.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS)
                        ?: continue
                    callback(packet)
                }
            } catch (_: InterruptedException) {
                // Expected on shutdown
            } catch (e: Exception) {
                Log.e(TAG, "Process thread error: ${e.message}")
            }
        }, "DisplayBridge-USB-Process")
        processThread?.isDaemon = true
        processThread?.start()

        // Read thread — streaming buffer approach:
        // Reads large chunks (USB_READ_SIZE = 16384, matching f_accessory's BULK_BUFFER_SIZE)
        // to consume full USB transfers. Accumulates in a buffer and parses complete packets.
        // This avoids partial reads that can lose data in f_accessory's acc_read().
        receiveThread = Thread({
            val input = inputStream ?: return@Thread
            Log.i(TAG, "Receive loop started (USB Accessory, streaming buffer, readSize=$USB_READ_SIZE)")

            val readBuf = ByteArray(USB_READ_SIZE)
            // Accumulation buffer for incoming USB data
            val accumulator = ByteArrayOutputStream(USB_READ_SIZE * 4)

            try {
                debugStatus = "waiting for first packet..."

                while (connected && !Thread.currentThread().isInterrupted) {
                    // Read a large chunk from USB — one read() = one acc_read() = one USB request.
                    // This is critical: f_accessory only has ONE USB request in flight at a time.
                    // By reading USB_READ_SIZE bytes, we consume the full USB transfer and
                    // minimize the gap before the next request is queued.
                    debugReadCalls++
                    val bytesRead = try {
                        input.read(readBuf, 0, USB_READ_SIZE)
                    } catch (e: IOException) {
                        if (connected) {
                            Log.e(TAG, "USB read error: ${e.message}")
                            debugStatus = "ERROR: ${e.message}"
                        }
                        break
                    }

                    if (bytesRead == -1) {
                        Log.w(TAG, "USB stream EOF after $debugReadCalls reads")
                        break
                    }

                    if (bytesRead == 0) {
                        continue
                    }

                    // Log first few reads for debugging USB transfer boundaries
                    if (debugReadCalls <= 10) {
                        Log.i(TAG, "USB read #$debugReadCalls: $bytesRead bytes (accumulator=${accumulator.size()})")
                    }

                    // Append to accumulation buffer
                    accumulator.write(readBuf, 0, bytesRead)
                    debugByteCount += bytesRead.toLong()

                    // Parse all complete packets from the accumulator
                    var data = accumulator.toByteArray()
                    var offset = 0

                    while (offset + PacketFramer.HEADER_SIZE <= data.size) {
                        // Find magic "DBRG" at current offset
                        if (data[offset] != 0x44.toByte() || data[offset + 1] != 0x42.toByte() ||
                            data[offset + 2] != 0x52.toByte() || data[offset + 3] != 0x47.toByte()) {
                            // Bad magic — scan forward for next magic
                            val syncPos = findMagic(data, offset + 1)
                            if (syncPos == -1) {
                                // No magic found in remaining data — discard all
                                Log.w(TAG, "No magic found, discarding ${data.size - offset} bytes")
                                offset = data.size
                                break
                            }
                            Log.w(TAG, "Bad magic at offset $offset, skipping ${syncPos - offset} bytes to re-sync")
                            offset = syncPos
                            continue
                        }

                        // Parse payload length from header bytes [24..27]
                        val payloadLength = (data[offset + 24].toInt() and 0xFF) or
                                ((data[offset + 25].toInt() and 0xFF) shl 8) or
                                ((data[offset + 26].toInt() and 0xFF) shl 16) or
                                ((data[offset + 27].toInt() and 0xFF) shl 24)

                        if (payloadLength < 0 || payloadLength > MAX_PAYLOAD_SIZE) {
                            Log.e(TAG, "Invalid payload length: $payloadLength at offset $offset, re-syncing")
                            val syncPos = findMagic(data, offset + 4)
                            offset = if (syncPos != -1) syncPos else data.size
                            continue
                        }

                        val totalPacketSize = PacketFramer.HEADER_SIZE + payloadLength

                        // Check if complete packet is available
                        if (offset + totalPacketSize > data.size) {
                            // Incomplete packet — wait for more data
                            break
                        }

                        // Extract complete packet
                        val fullPacket = data.copyOfRange(offset, offset + totalPacketSize)
                        offset += totalPacketSize

                        debugPacketCount++
                        debugStatus = "streaming pkts=$debugPacketCount"

                        if (debugPacketCount <= 5) {
                            val typeByte = fullPacket[4].toInt() and 0xFF
                            Log.i(TAG, "Packet #$debugPacketCount: type=0x${String.format("%02X", typeByte)} size=$totalPacketSize")
                        }

                        // Handle PING at transport level — respond immediately
                        val packetType = PacketFramer.peekPacketType(fullPacket)
                        if (packetType == PacketType.PING) {
                            try {
                                val parsed = PacketFramer.parsePacket(fullPacket)
                                val pong = PacketFramer.createPong(parsed.sequenceNumber, parsed.timestamp)
                                send(pong)
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to send PONG: ${e.message}")
                            }
                            continue
                        }

                        // Handle DISCONNECT/ERROR at transport level — break receive loop
                        // immediately so onComplete fires and triggers session cleanup.
                        // This is critical for USB: f_accessory read() blocks forever
                        // when the cable stays connected after server shutdown.
                        if (packetType == PacketType.DISCONNECT || packetType == PacketType.ERROR) {
                            Log.i(TAG, "Received ${packetType.name} packet from server — stopping receive loop")
                            packetQueue.put(fullPacket) // let ClientSession handle the message
                            // Give process thread a moment to handle the packet
                            Thread.sleep(100)
                            connected = false
                            break
                        }

                        packetQueue.put(fullPacket)
                    }

                    // Compact the accumulator: keep only unconsumed data
                    accumulator.reset()
                    if (offset < data.size) {
                        accumulator.write(data, offset, data.size - offset)
                    }
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
                Log.i(TAG, "Receive loop ended (pkts=$debugPacketCount, reads=$debugReadCalls, bytes=$debugByteCount)")
                debugStatus = "loop ended (pkts=$debugPacketCount)"
                processThread?.interrupt()
                onComplete?.invoke()
            }
        }, "DisplayBridge-USB-Read")

        receiveThread?.isDaemon = true
        receiveThread?.start()
    }

    /**
     * Finds the next occurrence of "DBRG" magic in data starting from startOffset.
     * Returns the offset or -1 if not found.
     */
    private fun findMagic(data: ByteArray, startOffset: Int): Int {
        for (i in startOffset..data.size - 4) {
            if (data[i] == 0x44.toByte() && data[i + 1] == 0x42.toByte() &&
                data[i + 2] == 0x52.toByte() && data[i + 3] == 0x47.toByte()) {
                return i
            }
        }
        return -1
    }

    override fun disconnect() {
        connected = false
        Log.i(TAG, "Disconnecting USB Accessory...")

        receiveThread?.interrupt()
        processThread?.interrupt()
        receiveThread = null
        processThread = null

        try { outputStream?.close() } catch (_: IOException) {}
        try { inputStream?.close() } catch (_: IOException) {}
        try { fileDescriptor?.close() } catch (_: IOException) {}

        outputStream = null
        inputStream = null
        fileDescriptor = null

        Log.i(TAG, "USB Accessory disconnected")
    }

    override fun isConnected(): Boolean = connected
}
