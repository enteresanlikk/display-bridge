import CoreMedia
import Foundation

public enum PacketType: UInt8, Sendable {
    case handshakeReq = 0x01
    case handshakeAck = 0x02
    case videoFrame   = 0x03
    case inputEvent   = 0x04
    case configUpdate = 0x05
    case ping         = 0x06
    case pong         = 0x07
    case error        = 0xFF
}

public enum PacketFramerError: Error, Sendable {
    case invalidMagic
    case invalidPacketType(UInt8)
    case insufficientData(expected: Int, actual: Int)
    case payloadLengthMismatch(expected: Int, actual: Int)
}

public enum PacketFramer {
    /// Header layout (28 bytes total):
    ///   [0..3]   magic "DBRG"
    ///   [4]      packet type
    ///   [5..7]   reserved
    ///   [8..15]  sequence number  (UInt64, little-endian)
    ///   [16..23] timestamp micros (UInt64, little-endian)
    ///   [24..27] payload length   (UInt32, little-endian)
    public static let headerSize = 28
    public static let magic: [UInt8] = [0x44, 0x42, 0x52, 0x47] // "DBRG"

    // MARK: - Generic packet creation / parsing

    public static func createPacket(
        type: PacketType,
        sequenceNumber: UInt64,
        timestamp: UInt64,
        payload: Data
    ) -> Data {
        var header = Data(capacity: headerSize + payload.count)

        // Magic (4 bytes)
        header.append(contentsOf: magic)

        // Packet type (1 byte)
        header.append(type.rawValue)

        // Reserved (3 bytes)
        header.append(contentsOf: [0x00, 0x00, 0x00])

        // Sequence number (8 bytes, LE)
        var seqLE = sequenceNumber.littleEndian
        header.append(Data(bytes: &seqLE, count: 8))

        // Timestamp (8 bytes, LE)
        var tsLE = timestamp.littleEndian
        header.append(Data(bytes: &tsLE, count: 8))

        // Payload length (4 bytes, LE)
        var lenLE = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &lenLE, count: 4))

        // Payload
        header.append(payload)

        return header
    }

    public static func parsePacket(
        from data: Data
    ) throws -> (type: PacketType, sequenceNumber: UInt64, timestamp: UInt64, payload: Data) {
        guard data.count >= headerSize else {
            throw PacketFramerError.insufficientData(expected: headerSize, actual: data.count)
        }

        // Validate magic
        let magicBytes = [UInt8](data[data.startIndex..<data.startIndex + 4])
        guard magicBytes == magic else {
            throw PacketFramerError.invalidMagic
        }

        // Packet type
        let rawType = data[data.startIndex + 4]
        guard let packetType = PacketType(rawValue: rawType) else {
            throw PacketFramerError.invalidPacketType(rawType)
        }

        // Sequence number (LE)
        let seqData = data[data.startIndex + 8..<data.startIndex + 16]
        let sequenceNumber = seqData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian

        // Timestamp (LE)
        let tsData = data[data.startIndex + 16..<data.startIndex + 24]
        let timestamp = tsData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian

        // Payload length (LE)
        let lenData = data[data.startIndex + 24..<data.startIndex + 28]
        let payloadLength = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)

        let totalExpected = headerSize + payloadLength
        guard data.count >= totalExpected else {
            throw PacketFramerError.payloadLengthMismatch(expected: totalExpected, actual: data.count)
        }

        let payload = data[data.startIndex + headerSize..<data.startIndex + headerSize + payloadLength]

        return (packetType, sequenceNumber, timestamp, Data(payload))
    }

    // MARK: - Video frame helpers

    /// Wraps an EncodedFrame into a full packet ready for transmission.
    /// Video payload format: [0] isKeyFrame (1 byte) + [1..3] reserved (3 bytes) + NAL data
    public static func wrapVideoFrame(_ frame: EncodedFrame) -> Data {
        var videoPayload = Data(capacity: 4 + frame.data.count)

        // 1 byte: isKeyFrame flag
        videoPayload.append(frame.isKeyFrame ? 1 : 0)

        // 3 bytes: reserved
        videoPayload.append(contentsOf: [0x00, 0x00, 0x00])

        // NAL unit data
        videoPayload.append(frame.data)

        let timestampMicros = UInt64(frame.timestamp.seconds * 1_000_000)

        return createPacket(
            type: .videoFrame,
            sequenceNumber: frame.sequenceNumber,
            timestamp: timestampMicros,
            payload: videoPayload
        )
    }

    /// Extracts an EncodedFrame from a video packet payload.
    public static func unwrapVideoFrame(
        payload: Data,
        sequenceNumber: UInt64,
        timestamp: UInt64
    ) -> EncodedFrame {
        let isKeyFrame = payload[payload.startIndex] != 0
        let nalData = Data(payload[(payload.startIndex + 4)...])
        let cmTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000)

        return EncodedFrame(
            timestamp: cmTime,
            data: nalData,
            isKeyFrame: isKeyFrame,
            sequenceNumber: sequenceNumber
        )
    }

}
