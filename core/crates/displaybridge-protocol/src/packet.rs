//! Packet framing: header encode/decode, buffer extraction, and video-frame helpers.
//!
//! Ported byte-for-byte from the original Swift/Kotlin `PacketFramer`.

use thiserror::Error;

/// 28-byte fixed header.
pub const HEADER_SIZE: usize = 28;

/// Magic prefix `"DBRG"`.
pub const MAGIC: [u8; 4] = [0x44, 0x42, 0x52, 0x47];

/// Video payload prefix: 1-byte keyframe flag + 3 reserved bytes before the NAL data.
pub const VIDEO_PREFIX_SIZE: usize = 4;

/// Largest payload the extractor will accept (16 MB). Guards against corrupt length fields.
pub const MAX_PAYLOAD_SIZE: usize = 16 * 1024 * 1024;

/// Wire packet type. Values are part of the protocol and must never change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PacketType {
    HandshakeReq = 0x01,
    HandshakeAck = 0x02,
    VideoFrame = 0x03,
    InputEvent = 0x04,
    ConfigUpdate = 0x05,
    Ping = 0x06,
    Pong = 0x07,
    Disconnect = 0x08,
    Error = 0xFF,
}

impl PacketType {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0x01 => Self::HandshakeReq,
            0x02 => Self::HandshakeAck,
            0x03 => Self::VideoFrame,
            0x04 => Self::InputEvent,
            0x05 => Self::ConfigUpdate,
            0x06 => Self::Ping,
            0x07 => Self::Pong,
            0x08 => Self::Disconnect,
            0xFF => Self::Error,
            _ => return None,
        })
    }
}

/// Errors from parsing a packet or buffer.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ParseError {
    #[error("invalid magic bytes")]
    InvalidMagic,
    #[error("invalid packet type: {0:#x}")]
    InvalidPacketType(u8),
    #[error("insufficient data: expected {expected}, got {actual}")]
    InsufficientData { expected: usize, actual: usize },
    #[error("payload length mismatch: expected {expected}, got {actual}")]
    PayloadLengthMismatch { expected: usize, actual: usize },
    #[error("payload too large: {0} bytes")]
    PayloadTooLarge(usize),
    #[error("invalid input event")]
    InvalidInput,
}

/// A parsed header plus a borrow of its payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PacketHeader {
    pub packet_type: PacketType,
    pub sequence_number: u64,
    pub timestamp_micros: u64,
    pub payload_len: usize,
}

/// An encoded video frame ready to be wrapped into a packet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub is_keyframe: bool,
    pub sequence_number: u64,
    pub timestamp_micros: u64,
}

/// Stateless framing helpers.
pub struct PacketFramer;

impl PacketFramer {
    /// Builds a complete packet (28-byte header + payload) in a single allocation.
    pub fn create_packet(
        packet_type: PacketType,
        sequence_number: u64,
        timestamp_micros: u64,
        payload: &[u8],
    ) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_SIZE + payload.len());
        write_header(
            &mut out,
            packet_type,
            sequence_number,
            timestamp_micros,
            payload.len() as u32,
        );
        out.extend_from_slice(payload);
        out
    }

    /// Parses a single packet from a buffer that must contain the whole packet.
    /// Returns the header and the payload slice.
    pub fn parse_packet(data: &[u8]) -> Result<(PacketHeader, &[u8]), ParseError> {
        if data.len() < HEADER_SIZE {
            return Err(ParseError::InsufficientData {
                expected: HEADER_SIZE,
                actual: data.len(),
            });
        }
        if data[0..4] != MAGIC {
            return Err(ParseError::InvalidMagic);
        }
        let raw_type = data[4];
        let packet_type =
            PacketType::from_u8(raw_type).ok_or(ParseError::InvalidPacketType(raw_type))?;

        let sequence_number = u64::from_le_bytes(data[8..16].try_into().unwrap());
        let timestamp_micros = u64::from_le_bytes(data[16..24].try_into().unwrap());
        let payload_len = u32::from_le_bytes(data[24..28].try_into().unwrap()) as usize;

        let total = HEADER_SIZE + payload_len;
        if data.len() < total {
            return Err(ParseError::PayloadLengthMismatch {
                expected: total,
                actual: data.len(),
            });
        }

        let header = PacketHeader {
            packet_type,
            sequence_number,
            timestamp_micros,
            payload_len,
        };
        Ok((header, &data[HEADER_SIZE..total]))
    }

    /// Drains all complete packets from a streaming receive buffer, returning them
    /// and removing the consumed bytes. On invalid magic or an oversized payload the
    /// buffer is cleared (matches the Swift/Kotlin resync behavior).
    pub fn extract_packets(buffer: &mut Vec<u8>) -> Vec<Vec<u8>> {
        let mut packets = Vec::new();
        let mut consumed = 0usize;

        loop {
            let remaining = &buffer[consumed..];
            if remaining.len() < HEADER_SIZE {
                break;
            }
            if remaining[0..4] != MAGIC {
                buffer.clear();
                return packets;
            }
            let payload_len =
                u32::from_le_bytes(remaining[24..28].try_into().unwrap()) as usize;
            if payload_len > MAX_PAYLOAD_SIZE {
                buffer.clear();
                return packets;
            }
            let total = HEADER_SIZE + payload_len;
            if remaining.len() < total {
                break;
            }
            packets.push(remaining[..total].to_vec());
            consumed += total;
        }

        if consumed > 0 {
            buffer.drain(..consumed);
        }
        packets
    }

    /// Wraps an encoded frame into a `VideoFrame` packet: header + [keyframe flag +
    /// 3 reserved] + NAL data, in a single allocation.
    pub fn wrap_video_frame(frame: &EncodedFrame) -> Vec<u8> {
        let payload_len = VIDEO_PREFIX_SIZE + frame.data.len();
        let mut out = Vec::with_capacity(HEADER_SIZE + payload_len);
        write_header(
            &mut out,
            PacketType::VideoFrame,
            frame.sequence_number,
            frame.timestamp_micros,
            payload_len as u32,
        );
        out.push(if frame.is_keyframe { 1 } else { 0 });
        out.extend_from_slice(&[0, 0, 0]);
        out.extend_from_slice(&frame.data);
        out
    }

    /// Extracts an `EncodedFrame` from a video packet payload.
    pub fn unwrap_video_frame(
        payload: &[u8],
        sequence_number: u64,
        timestamp_micros: u64,
    ) -> Result<EncodedFrame, ParseError> {
        if payload.len() < VIDEO_PREFIX_SIZE {
            return Err(ParseError::InsufficientData {
                expected: VIDEO_PREFIX_SIZE,
                actual: payload.len(),
            });
        }
        Ok(EncodedFrame {
            is_keyframe: payload[0] != 0,
            data: payload[VIDEO_PREFIX_SIZE..].to_vec(),
            sequence_number,
            timestamp_micros,
        })
    }
}

/// Writes the 28-byte header into `out`.
fn write_header(
    out: &mut Vec<u8>,
    packet_type: PacketType,
    sequence_number: u64,
    timestamp_micros: u64,
    payload_len: u32,
) {
    out.extend_from_slice(&MAGIC);
    out.push(packet_type as u8);
    out.extend_from_slice(&[0, 0, 0]); // reserved
    out.extend_from_slice(&sequence_number.to_le_bytes());
    out.extend_from_slice(&timestamp_micros.to_le_bytes());
    out.extend_from_slice(&payload_len.to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_is_28_bytes_and_little_endian() {
        let pkt = PacketFramer::create_packet(PacketType::Ping, 0x0102_0304_0506_0708, 0xAABB, &[]);
        assert_eq!(pkt.len(), HEADER_SIZE);
        assert_eq!(&pkt[0..4], &MAGIC);
        assert_eq!(pkt[4], 0x06); // ping
        assert_eq!(&pkt[5..8], &[0, 0, 0]); // reserved
        // sequence LE
        assert_eq!(&pkt[8..16], &[0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]);
        // timestamp LE
        assert_eq!(&pkt[16..24], &[0xBB, 0xAA, 0, 0, 0, 0, 0, 0]);
        // payload length LE
        assert_eq!(&pkt[24..28], &[0, 0, 0, 0]);
    }

    #[test]
    fn create_then_parse_roundtrips() {
        let payload = b"hello world";
        let pkt = PacketFramer::create_packet(PacketType::HandshakeReq, 42, 999, payload);
        let (header, parsed) = PacketFramer::parse_packet(&pkt).unwrap();
        assert_eq!(header.packet_type, PacketType::HandshakeReq);
        assert_eq!(header.sequence_number, 42);
        assert_eq!(header.timestamp_micros, 999);
        assert_eq!(header.payload_len, payload.len());
        assert_eq!(parsed, payload);
    }

    #[test]
    fn parse_rejects_bad_magic() {
        let mut pkt = PacketFramer::create_packet(PacketType::Ping, 1, 1, &[]);
        pkt[0] = 0x00;
        assert_eq!(PacketFramer::parse_packet(&pkt), Err(ParseError::InvalidMagic));
    }

    #[test]
    fn parse_rejects_unknown_type() {
        let mut pkt = PacketFramer::create_packet(PacketType::Ping, 1, 1, &[]);
        pkt[4] = 0x99;
        assert_eq!(
            PacketFramer::parse_packet(&pkt),
            Err(ParseError::InvalidPacketType(0x99))
        );
    }

    #[test]
    fn video_frame_roundtrips() {
        let frame = EncodedFrame {
            data: vec![0xDE, 0xAD, 0xBE, 0xEF],
            is_keyframe: true,
            sequence_number: 7,
            timestamp_micros: 123_456,
        };
        let pkt = PacketFramer::wrap_video_frame(&frame);
        let (header, payload) = PacketFramer::parse_packet(&pkt).unwrap();
        assert_eq!(header.packet_type, PacketType::VideoFrame);
        assert_eq!(header.payload_len, VIDEO_PREFIX_SIZE + frame.data.len());
        // keyframe flag + reserved
        assert_eq!(payload[0], 1);
        assert_eq!(&payload[1..4], &[0, 0, 0]);
        let out = PacketFramer::unwrap_video_frame(payload, header.sequence_number, header.timestamp_micros).unwrap();
        assert_eq!(out, frame);
    }

    #[test]
    fn extract_pulls_multiple_packets_and_keeps_remainder() {
        let a = PacketFramer::create_packet(PacketType::Ping, 1, 1, b"aa");
        let b = PacketFramer::create_packet(PacketType::Pong, 2, 2, b"bbbb");
        let mut buffer = Vec::new();
        buffer.extend_from_slice(&a);
        buffer.extend_from_slice(&b);
        // append a partial third packet (header only, claims 100 bytes)
        let c = PacketFramer::create_packet(PacketType::Ping, 3, 3, &vec![0u8; 100]);
        buffer.extend_from_slice(&c[..HEADER_SIZE + 10]); // incomplete

        let packets = PacketFramer::extract_packets(&mut buffer);
        assert_eq!(packets.len(), 2);
        assert_eq!(packets[0], a);
        assert_eq!(packets[1], b);
        // remainder is the incomplete packet, untouched
        assert_eq!(buffer.len(), HEADER_SIZE + 10);
    }

    #[test]
    fn extract_clears_buffer_on_bad_magic() {
        let mut buffer = vec![0xFFu8; 40];
        let packets = PacketFramer::extract_packets(&mut buffer);
        assert!(packets.is_empty());
        assert!(buffer.is_empty());
    }

    #[test]
    fn extract_clears_buffer_on_oversized_payload() {
        let mut pkt = PacketFramer::create_packet(PacketType::Ping, 1, 1, &[]);
        // corrupt the length field to exceed MAX_PAYLOAD_SIZE
        pkt[24..28].copy_from_slice(&(MAX_PAYLOAD_SIZE as u32 + 1).to_le_bytes());
        let mut buffer = pkt;
        let packets = PacketFramer::extract_packets(&mut buffer);
        assert!(packets.is_empty());
        assert!(buffer.is_empty());
    }
}
