package com.displaybridge.client.transport

/**
 * Common interface for DisplayBridge transport implementations.
 * Both TCP (Network) and USB Accessory transports implement this.
 */
interface Transport {
    fun connect()
    fun send(data: ByteArray)
    fun receiveLoop(callback: (ByteArray) -> Unit, onComplete: (() -> Unit)? = null)
    fun disconnect()
    fun isConnected(): Boolean
}
