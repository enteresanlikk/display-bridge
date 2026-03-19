package com.displaybridge.client.protocol

import com.displaybridge.client.model.DeviceConfig
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Binary packet framer matching the DisplayBridge wire protocol.
 *
 * Header layout (28 bytes, little-endian):
 *   [0..3]   magic   "DBRG" (4 bytes)
 *   [4]      type    PacketType value (1 byte)
 *   [5..7]   reserved (3 bytes, zeroed)
 *   [8..15]  sequence number (UInt64 LE)
 *   [16..23] timestamp in microseconds (UInt64 LE)
 *   [24..27] payload length (UInt32 LE)
 */
object PacketFramer {

    const val HEADER_SIZE = 28

    val MAGIC = byteArrayOf(0x44, 0x42, 0x52, 0x47) // "DBRG"

    data class ParsedPacket(
        val type: PacketType,
        val sequenceNumber: Long,
        val timestamp: Long,
        val payload: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is ParsedPacket) return false
            return type == other.type &&
                sequenceNumber == other.sequenceNumber &&
                timestamp == other.timestamp &&
                payload.contentEquals(other.payload)
        }

        override fun hashCode(): Int {
            var result = type.hashCode()
            result = 31 * result + sequenceNumber.hashCode()
            result = 31 * result + timestamp.hashCode()
            result = 31 * result + payload.contentHashCode()
            return result
        }
    }

    /**
     * Creates a complete packet (header + payload) for the given parameters.
     */
    fun createPacket(
        type: PacketType,
        sequenceNumber: Long,
        timestamp: Long,
        payload: ByteArray
    ): ByteArray {
        val buffer = ByteBuffer.allocate(HEADER_SIZE + payload.size)
        buffer.order(ByteOrder.LITTLE_ENDIAN)

        // Magic
        buffer.put(MAGIC)
        // Type
        buffer.put(type.value)
        // Reserved (3 bytes)
        buffer.put(0)
        buffer.put(0)
        buffer.put(0)
        // Sequence number (8 bytes)
        buffer.putLong(sequenceNumber)
        // Timestamp (8 bytes)
        buffer.putLong(timestamp)
        // Payload length (4 bytes)
        buffer.putInt(payload.size)
        // Payload
        buffer.put(payload)

        return buffer.array()
    }

    /**
     * Parses a complete packet (header + payload) from raw bytes.
     *
     * @throws IllegalArgumentException if data is too short or magic bytes don't match.
     * @throws IllegalArgumentException if packet type is unknown.
     */
    fun parsePacket(data: ByteArray): ParsedPacket {
        require(data.size >= HEADER_SIZE) {
            "Data too short for header: ${data.size} bytes, need at least $HEADER_SIZE"
        }

        val buffer = ByteBuffer.wrap(data)
        buffer.order(ByteOrder.LITTLE_ENDIAN)

        // Validate magic
        val magic = ByteArray(4)
        buffer.get(magic)
        require(magic.contentEquals(MAGIC)) {
            "Invalid magic bytes: ${magic.map { it.toInt() and 0xFF }}"
        }

        // Type
        val typeByte = buffer.get()
        val type = PacketType.fromValue(typeByte)
            ?: throw IllegalArgumentException("Unknown packet type: 0x${String.format("%02X", typeByte)}")

        // Reserved (skip 3 bytes)
        buffer.get()
        buffer.get()
        buffer.get()

        // Sequence number
        val sequenceNumber = buffer.getLong()

        // Timestamp
        val timestamp = buffer.getLong()

        // Payload length
        val payloadLength = buffer.getInt()

        require(data.size >= HEADER_SIZE + payloadLength) {
            "Data too short for payload: have ${data.size - HEADER_SIZE} bytes, need $payloadLength"
        }

        // Payload
        val payload = ByteArray(payloadLength)
        buffer.get(payload)

        return ParsedPacket(
            type = type,
            sequenceNumber = sequenceNumber,
            timestamp = timestamp,
            payload = payload
        )
    }

    /**
     * Reads the packet type from a raw packet without full parsing.
     * Returns null if the data is too short.
     */
    fun peekPacketType(data: ByteArray): PacketType? {
        if (data.size < 5) return null
        return PacketType.fromValue(data[4])
    }

    /**
     * Creates a HANDSHAKE_REQ packet with the device configuration as JSON payload.
     */
    fun createHandshakeRequest(config: DeviceConfig): ByteArray {
        val jsonPayload = config.toJson().toByteArray(Charsets.UTF_8)
        val timestamp = System.nanoTime() / 1000 // microseconds
        return createPacket(
            type = PacketType.HANDSHAKE_REQ,
            sequenceNumber = 0,
            timestamp = timestamp,
            payload = jsonPayload
        )
    }

    /**
     * Parses a video frame payload.
     *
     * Video frame payload layout:
     *   [0]     isKeyFrame (1 byte, 0x01 = key frame, 0x00 = not)
     *   [1..3]  reserved (3 bytes)
     *   [4..]   H.265 NAL unit data
     *
     * @return Pair of (isKeyFrame, nalData)
     */
    fun parseVideoFrame(payload: ByteArray): Pair<Boolean, ByteArray> {
        require(payload.size >= 4) {
            "Video frame payload too short: ${payload.size} bytes, need at least 4"
        }

        val isKeyFrame = payload[0] == 0x01.toByte()
        val nalData = payload.copyOfRange(4, payload.size)

        return Pair(isKeyFrame, nalData)
    }

    /**
     * Creates a CONFIG_UPDATE packet with new device configuration.
     */
    fun createConfigUpdate(config: DeviceConfig): ByteArray {
        val jsonPayload = config.toJson().toByteArray(Charsets.UTF_8)
        val timestamp = System.nanoTime() / 1000
        return createPacket(
            type = PacketType.CONFIG_UPDATE,
            sequenceNumber = 0,
            timestamp = timestamp,
            payload = jsonPayload
        )
    }

    /**
     * Creates a PONG packet (response to server PING).
     */
    fun createPong(sequenceNumber: Long, timestamp: Long): ByteArray {
        return createPacket(
            type = PacketType.PONG,
            sequenceNumber = sequenceNumber,
            timestamp = timestamp,
            payload = ByteArray(0)
        )
    }
}
