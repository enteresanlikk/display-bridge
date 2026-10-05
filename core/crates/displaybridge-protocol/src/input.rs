//! Pointer input sent from a sink back to its source (`PacketType::InputEvent`).
//!
//! ## Payload layout (24 bytes, little-endian)
//! ```text
//! [0]      kind      (0 down, 1 move, 2 up, 3 scroll, 4 hover)
//! [1]      button    (0 primary, 1 secondary)
//! [2..3]   reserved
//! [4..7]   x         (f32, 0..1 across the display width)
//! [8..11]  y         (f32, 0..1 down the display height)
//! [12..15] dx        (f32, scroll delta as a fraction of the display width)
//! [16..19] dy        (f32, scroll delta as a fraction of the display height)
//! [20..23] pressure  (f32, 0..1; 1.0 for a plain touch or click)
//! ```
//! Coordinates are normalized so the sink never needs to know the source's point
//! size, and a `ConfigUpdate` mid-drag can't leave the two sides disagreeing.

use crate::packet::ParseError;

/// Size of an encoded [`InputEvent`] payload.
pub const INPUT_EVENT_SIZE: usize = 24;

/// What the pointer did.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputKind {
    /// Button / finger / pen tip went down.
    Down = 0,
    /// Pointer moved while down (a drag).
    Move = 1,
    /// Button / finger / pen tip lifted.
    Up = 2,
    /// Scroll by (`dx`, `dy`) at (`x`, `y`).
    Scroll = 3,
    /// Pointer moved with nothing pressed.
    Hover = 4,
}

impl InputKind {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Down,
            1 => Self::Move,
            2 => Self::Up,
            3 => Self::Scroll,
            4 => Self::Hover,
            _ => return None,
        })
    }
}

/// One pointer event. See the module docs for units.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InputEvent {
    pub kind: InputKind,
    pub button: u8,
    pub x: f32,
    pub y: f32,
    pub dx: f32,
    pub dy: f32,
    pub pressure: f32,
}

impl InputEvent {
    pub fn encode(&self) -> [u8; INPUT_EVENT_SIZE] {
        let mut out = [0u8; INPUT_EVENT_SIZE];
        out[0] = self.kind as u8;
        out[1] = self.button;
        out[4..8].copy_from_slice(&self.x.to_le_bytes());
        out[8..12].copy_from_slice(&self.y.to_le_bytes());
        out[12..16].copy_from_slice(&self.dx.to_le_bytes());
        out[16..20].copy_from_slice(&self.dy.to_le_bytes());
        out[20..24].copy_from_slice(&self.pressure.to_le_bytes());
        out
    }

    /// Decodes and sanitizes a payload from the peer. The payload is untrusted: an
    /// unknown kind or a non-finite float is rejected, and positions / pressure are
    /// clamped to `0..1` so a hostile sink can't steer the pointer off its display.
    pub fn decode(payload: &[u8]) -> Result<Self, ParseError> {
        if payload.len() < INPUT_EVENT_SIZE {
            return Err(ParseError::InsufficientData {
                expected: INPUT_EVENT_SIZE,
                actual: payload.len(),
            });
        }
        let kind = InputKind::from_u8(payload[0]).ok_or(ParseError::InvalidInput)?;
        let f = |at: usize| f32::from_le_bytes(payload[at..at + 4].try_into().unwrap());
        let (x, y, dx, dy, pressure) = (f(4), f(8), f(12), f(16), f(20));
        if ![x, y, dx, dy, pressure].iter().all(|v| v.is_finite()) {
            return Err(ParseError::InvalidInput);
        }
        Ok(InputEvent {
            kind,
            button: payload[1],
            x: x.clamp(0.0, 1.0),
            y: y.clamp(0.0, 1.0),
            // A single scroll step never needs to exceed one full display.
            dx: dx.clamp(-1.0, 1.0),
            dy: dy.clamp(-1.0, 1.0),
            pressure: pressure.clamp(0.0, 1.0),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> InputEvent {
        InputEvent {
            kind: InputKind::Scroll,
            button: 1,
            x: 0.25,
            y: 0.75,
            dx: -0.5,
            dy: 0.125,
            pressure: 0.5,
        }
    }

    #[test]
    fn layout_is_24_bytes_little_endian() {
        let bytes = sample().encode();
        assert_eq!(bytes.len(), INPUT_EVENT_SIZE);
        assert_eq!(bytes[0], 3); // scroll
        assert_eq!(bytes[1], 1); // secondary button
        assert_eq!(&bytes[2..4], &[0, 0]); // reserved
        assert_eq!(&bytes[4..8], &0.25f32.to_le_bytes());
        assert_eq!(&bytes[8..12], &0.75f32.to_le_bytes());
        assert_eq!(&bytes[12..16], &(-0.5f32).to_le_bytes());
        assert_eq!(&bytes[16..20], &0.125f32.to_le_bytes());
        assert_eq!(&bytes[20..24], &0.5f32.to_le_bytes());
    }

    #[test]
    fn encode_then_decode_roundtrips() {
        assert_eq!(InputEvent::decode(&sample().encode()), Ok(sample()));
    }

    #[test]
    fn decode_rejects_short_unknown_and_non_finite() {
        assert!(matches!(
            InputEvent::decode(&[0u8; INPUT_EVENT_SIZE - 1]),
            Err(ParseError::InsufficientData { .. })
        ));

        let mut unknown = sample().encode();
        unknown[0] = 9;
        assert_eq!(InputEvent::decode(&unknown), Err(ParseError::InvalidInput));

        let mut nan = sample().encode();
        nan[4..8].copy_from_slice(&f32::NAN.to_le_bytes());
        assert_eq!(InputEvent::decode(&nan), Err(ParseError::InvalidInput));
    }

    #[test]
    fn decode_clamps_out_of_range_values() {
        let wild = InputEvent {
            kind: InputKind::Down,
            button: 0,
            x: -3.0,
            y: 7.0,
            dx: 50.0,
            dy: -50.0,
            pressure: 2.0,
        };
        let got = InputEvent::decode(&wild.encode()).unwrap();
        assert_eq!((got.x, got.y), (0.0, 1.0));
        assert_eq!((got.dx, got.dy), (1.0, -1.0));
        assert_eq!(got.pressure, 1.0);
    }
}
