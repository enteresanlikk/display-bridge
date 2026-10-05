//! DisplayBridge wire protocol — the single source of truth.
//!
//! This crate replaces the hand-synchronized Swift (`PacketFramer.swift`) and
//! Kotlin (`PacketFramer.kt`) copies. The byte layout is verified by unit tests
//! (see `tests` module) so any drift is a build failure, not a runtime surprise.
//!
//! ## Header layout (28 bytes, little-endian)
//! ```text
//! [0..3]   magic "DBRG"
//! [4]      packet type
//! [5..7]   reserved (3 bytes)
//! [8..15]  sequence number  (u64 LE)
//! [16..23] timestamp micros (u64 LE)
//! [24..27] payload length   (u32 LE)
//! ```
//!
//! ## Video payload layout
//! ```text
//! [0]      keyframe flag (1 = keyframe)
//! [1..3]   reserved (3 bytes)
//! [4..]    NAL data
//! ```

mod config;
mod input;
mod packet;

pub use config::{Capabilities, DeviceConfig, Platform, ProtocolError, Role, VideoCodec, PROTOCOL_VERSION};
pub use input::{InputEvent, InputKind, INPUT_EVENT_SIZE};
pub use packet::{
    EncodedFrame, PacketFramer, PacketHeader, PacketType, ParseError, HEADER_SIZE, MAGIC,
    MAX_PAYLOAD_SIZE, VIDEO_PREFIX_SIZE,
};
