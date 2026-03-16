package com.displaybridge.client.protocol

enum class PacketType(val value: Byte) {
    HANDSHAKE_REQ(0x01),
    HANDSHAKE_ACK(0x02),
    VIDEO_FRAME(0x03),
    INPUT_EVENT(0x04),
    CONFIG_UPDATE(0x05),
    PING(0x06),
    PONG(0x07),
    ERROR(0xFF.toByte());

    companion object {
        fun fromValue(value: Byte): PacketType? = entries.find { it.value == value }
    }
}
