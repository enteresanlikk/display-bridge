package com.displaybridge.client.decoder

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.util.concurrent.locks.ReentrantLock

/**
 * Hardware-accelerated H.265 (HEVC) decoder using MediaCodec async callback mode.
 *
 * Uses async callbacks for zero-blocking decode:
 * - onInputBufferAvailable: immediately feeds the latest frame (drops stale ones)
 * - onOutputBufferAvailable: immediately renders to Surface
 *
 * The receive thread is NEVER blocked by decoder operations.
 */
class HardwareDecoder {

    companion object {
        private const val TAG = "HardwareDecoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_HEVC

        // HEVC NAL unit types for parameter sets
        private const val NAL_TYPE_VPS = 32
        private const val NAL_TYPE_SPS = 33
        private const val NAL_TYPE_PPS = 34
    }

    private var codec: MediaCodec? = null
    private var isConfigured = false
    private var csdSubmitted = false
    private var frameCount = 0L
    private var droppedCount = 0L
    private var decodedCount = 0L

    private data class FrameData(
        val data: ByteArray,
        val timestampUs: Long,
        val flags: Int
    )

    // Lock protects pendingFrames and freeInputBuffers
    private val queueLock = ReentrantLock()

    // Frames waiting to be submitted to the decoder
    private val pendingFrames = ArrayDeque<FrameData>()

    // Input buffer indices returned by onInputBufferAvailable when no frame was ready
    private val freeInputBuffers = ArrayDeque<Int>()

    /**
     * Configures the decoder in async callback mode.
     */
    fun configure(width: Int, height: Int, surface: Surface) {
        if (isConfigured) {
            Log.w(TAG, "Already configured, releasing first")
            release()
        }

        Log.i(TAG, "Configuring HEVC decoder (async): ${width}x${height}")

        val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height)
        format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)

        val decoder = MediaCodec.createDecoderByType(MIME_TYPE)

        // Async callback — MUST be set before configure()
        decoder.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
                queueLock.lock()
                try {
                    val frame = dequeueNextFrame()
                    if (frame != null) {
                        submitToDecoder(mc, index, frame)
                    } else {
                        // No frame ready — park this buffer index for later
                        freeInputBuffers.addLast(index)
                    }
                } finally {
                    queueLock.unlock()
                }
            }

            override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    // Render immediately — no timestamp-based scheduling (lowest latency)
                    mc.releaseOutputBuffer(index, true)
                    decodedCount++
                } catch (e: Exception) {
                    Log.e(TAG, "Error releasing output: ${e.message}")
                }
            }

            override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "Decoder error: ${e.message}")
            }

            override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
                Log.i(TAG, "Output format: $format")
            }
        })

        decoder.configure(format, surface, null, 0)
        decoder.start()

        codec = decoder
        isConfigured = true
        csdSubmitted = false
        frameCount = 0
        droppedCount = 0
        decodedCount = 0

        Log.i(TAG, "HEVC decoder ready (async mode)")
    }

    /**
     * Queues an encoded H.265 sample for decoding.
     * Returns immediately — NEVER blocks the calling thread.
     */
    fun decodeSample(data: ByteArray, isKeyFrame: Boolean, timestampUs: Long) {
        if (!isConfigured) return

        frameCount++

        queueLock.lock()
        try {
            if (isKeyFrame && !csdSubmitted) {
                // First keyframe: separate CSD (VPS/SPS/PPS) and IDR frame
                val (csdData, frameData) = splitCsdAndFrame(data)

                if (csdData != null) {
                    Log.i(TAG, "Queueing CSD: ${csdData.size} bytes")
                    pendingFrames.addLast(FrameData(csdData, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG))
                }
                if (frameData != null) {
                    Log.i(TAG, "Queueing first IDR: ${frameData.size} bytes")
                    pendingFrames.addLast(FrameData(frameData, timestampUs, MediaCodec.BUFFER_FLAG_KEY_FRAME))
                }
                csdSubmitted = true
            } else {
                // Drop all old non-CSD frames — always show latest
                val iter = pendingFrames.iterator()
                while (iter.hasNext()) {
                    val f = iter.next()
                    if (f.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        iter.remove()
                        droppedCount++
                    }
                }

                val flags = if (isKeyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                pendingFrames.addLast(FrameData(data, timestampUs, flags))
            }

            // If decoder has free input buffers, feed them now
            feedFreeBuffers()
        } finally {
            queueLock.unlock()
        }

        if (frameCount % 120 == 0L) {
            Log.i(TAG, "Stats: recv=$frameCount decoded=$decodedCount dropped=$droppedCount pending=${pendingFrames.size}")
        }
    }

    // Must be called with queueLock held
    private fun feedFreeBuffers() {
        val mc = codec ?: return
        while (freeInputBuffers.isNotEmpty() && pendingFrames.isNotEmpty()) {
            val index = freeInputBuffers.removeFirst()
            val frame = dequeueNextFrame() ?: break
            submitToDecoder(mc, index, frame)
        }
    }

    /**
     * Gets the next frame to decode.
     * CSD frames are always returned first (in order).
     * For non-CSD frames, returns the LATEST and drops intermediate ones.
     * Must be called with queueLock held.
     */
    private fun dequeueNextFrame(): FrameData? {
        if (pendingFrames.isEmpty()) return null

        // CSD must be returned first and in order — never skip
        val first = pendingFrames.first()
        if (first.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            return pendingFrames.removeFirst()
        }

        // For regular frames: take the latest, drop intermediate
        if (pendingFrames.size > 1) {
            val latest = pendingFrames.removeLast()
            val dropped = pendingFrames.size
            pendingFrames.clear()
            droppedCount += dropped
            return latest
        }

        return pendingFrames.removeFirst()
    }

    private fun submitToDecoder(mc: MediaCodec, index: Int, frame: FrameData) {
        try {
            val buffer = mc.getInputBuffer(index) ?: return
            buffer.clear()
            buffer.put(frame.data)
            mc.queueInputBuffer(index, 0, frame.data.size, frame.timestampUs, frame.flags)
        } catch (e: Exception) {
            Log.e(TAG, "Submit error: ${e.message}")
        }
    }

    /**
     * Splits Annex B NAL data into CSD (VPS/SPS/PPS) and frame (IDR) parts.
     */
    private fun splitCsdAndFrame(data: ByteArray): Pair<ByteArray?, ByteArray?> {
        val nalUnits = parseAnnexBNals(data)

        val csdParts = mutableListOf<Pair<Int, Int>>()
        val frameParts = mutableListOf<Pair<Int, Int>>()

        for ((offset, length) in nalUnits) {
            val nalHeaderOffset = offset + 4 // skip 4-byte start code
            if (nalHeaderOffset >= data.size) continue

            val nalType = (data[nalHeaderOffset].toInt() shr 1) and 0x3F

            if (nalType in NAL_TYPE_VPS..NAL_TYPE_PPS) {
                csdParts.add(Pair(offset, length))
            } else {
                frameParts.add(Pair(offset, length))
            }
        }

        val csd = if (csdParts.isNotEmpty()) {
            val size = csdParts.sumOf { it.second }
            val buf = ByteArray(size)
            var pos = 0
            for ((offset, length) in csdParts) {
                System.arraycopy(data, offset, buf, pos, length)
                pos += length
            }
            buf
        } else null

        val frame = if (frameParts.isNotEmpty()) {
            val size = frameParts.sumOf { it.second }
            val buf = ByteArray(size)
            var pos = 0
            for ((offset, length) in frameParts) {
                System.arraycopy(data, offset, buf, pos, length)
                pos += length
            }
            buf
        } else null

        return Pair(csd, frame)
    }

    /**
     * Parses Annex B format data to find NAL unit boundaries (4-byte start codes).
     */
    private fun parseAnnexBNals(data: ByteArray): List<Pair<Int, Int>> {
        val nals = mutableListOf<Int>()

        var i = 0
        while (i + 3 < data.size) {
            if (data[i] == 0x00.toByte() &&
                data[i + 1] == 0x00.toByte() &&
                data[i + 2] == 0x00.toByte() &&
                data[i + 3] == 0x01.toByte()
            ) {
                nals.add(i)
                i += 4
            } else {
                i++
            }
        }

        if (nals.isEmpty()) return emptyList()

        val result = mutableListOf<Pair<Int, Int>>()
        for (j in 0 until nals.size) {
            val start = nals[j]
            val end = if (j + 1 < nals.size) nals[j + 1] else data.size
            result.add(Pair(start, end - start))
        }

        return result
    }

    /**
     * Releases the decoder and frees all resources.
     */
    fun release() {
        Log.i(TAG, "Releasing decoder (decoded=$decodedCount dropped=$droppedCount)")

        try {
            codec?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping decoder: ${e.message}")
        }

        try {
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing decoder: ${e.message}")
        }

        codec = null
        isConfigured = false
        csdSubmitted = false
        frameCount = 0
        droppedCount = 0
        decodedCount = 0

        queueLock.lock()
        try {
            pendingFrames.clear()
            freeInputBuffers.clear()
        } finally {
            queueLock.unlock()
        }

        Log.i(TAG, "Decoder released")
    }
}
