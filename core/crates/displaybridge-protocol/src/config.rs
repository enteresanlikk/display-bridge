//! Negotiation structs: `DeviceConfig` (wire-compatible with the existing JSON)
//! and the protocol-v2 `Capabilities` exchange.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Protocol version advertised in the handshake. Bump on any breaking wire change.
pub const PROTOCOL_VERSION: u32 = 2;

/// Video codec. Serializes to the exact lowercase strings the Swift/Kotlin sides use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VideoCodec {
    /// H.265 / HEVC.
    Hevc,
    /// H.264 / AVC.
    H264,
    /// AV1 — reserved for post-v2; not negotiated yet.
    Av1,
}

impl Default for VideoCodec {
    fn default() -> Self {
        VideoCodec::Hevc
    }
}

/// The role a peer plays in a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// Owns a virtual/extended display, captures and encodes it. (was "server")
    Source,
    /// Receives frames, decodes and renders them as a monitor. (was "client")
    Sink,
}

/// Reporting platform, used for diagnostics and capability defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Macos,
    Windows,
    Linux,
    Android,
    Ios,
    Ipados,
    /// Anything else, including names a newer peer uses that this build has not heard of:
    /// an unfamiliar platform must not make the handshake unparseable.
    #[serde(other)]
    Unknown,
}

impl Platform {
    /// The platform this code was compiled for.
    pub fn current() -> Self {
        match std::env::consts::OS {
            "macos" => Platform::Macos,
            "windows" => Platform::Windows,
            "linux" => Platform::Linux,
            "android" => Platform::Android,
            // iPhone and iPad share one target; the app can say "ipados" itself.
            "ios" => Platform::Ios,
            _ => Platform::Unknown,
        }
    }
}

/// The per-connection display configuration. Field names and the `codec` string
/// values match the existing `DeviceConfig` JSON on both Swift and Kotlin, so a
/// v2 core stays wire-compatible with the current apps for the HEVC/TCP path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceConfig {
    pub width: i32,
    pub height: i32,
    #[serde(rename = "refreshRate")]
    pub refresh_rate: i32,
    #[serde(default)]
    pub codec: VideoCodec,
    #[serde(rename = "deviceName", default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    /// What the sink runs on, so the source can show it next to the device name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<Platform>,
    /// The pairing code shown on the source, presented by a sink in its handshake.
    /// Never echoed back in the ack.
    #[serde(rename = "pairingCode", default, skip_serializing_if = "Option::is_none")]
    pub pairing_code: Option<String>,
}

impl DeviceConfig {
    pub fn new(width: i32, height: i32, refresh_rate: i32, codec: VideoCodec) -> Self {
        Self {
            width,
            height,
            refresh_rate,
            codec,
            device_name: None,
            platform: None,
            pairing_code: None,
        }
    }

    /// Serializes to the canonical JSON used on the wire.
    pub fn to_json(&self) -> Result<String, ProtocolError> {
        serde_json::to_string(self).map_err(|e| ProtocolError::Json(e.to_string()))
    }

    /// Parses from the canonical wire JSON.
    pub fn from_json(s: &str) -> Result<Self, ProtocolError> {
        serde_json::from_str(s).map_err(|e| ProtocolError::Json(e.to_string()))
    }

    /// Validates dimensions and refresh rate against supported bounds.
    /// Mirrors the range check in the current `SessionCoordinator.validateConfig`.
    pub fn validate(&self) -> Result<(), ProtocolError> {
        let ok = (1..=7680).contains(&self.width)
            && (1..=4320).contains(&self.height)
            && (1..=240).contains(&self.refresh_rate);
        if ok {
            Ok(())
        } else {
            Err(ProtocolError::InvalidConfig(format!(
                "{}x{}@{}Hz",
                self.width, self.height, self.refresh_rate
            )))
        }
    }
}

/// Protocol-v2 capability advertisement, exchanged alongside the handshake so
/// either peer can pick a mutually supported codec and detect version skew.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: u32,
    pub role: Role,
    pub platform: Platform,
    /// Supported codecs in the peer's preference order (most preferred first).
    #[serde(rename = "supportedCodecs")]
    pub supported_codecs: Vec<VideoCodec>,
    #[serde(rename = "maxWidth")]
    pub max_width: i32,
    #[serde(rename = "maxHeight")]
    pub max_height: i32,
    #[serde(rename = "maxRefreshRate")]
    pub max_refresh_rate: i32,
}

impl Capabilities {
    /// Chooses the first codec this peer prefers that `other` also supports.
    /// Returns `None` when the two share no codec.
    pub fn negotiate_codec(&self, other: &Capabilities) -> Option<VideoCodec> {
        self.supported_codecs
            .iter()
            .copied()
            .find(|c| other.supported_codecs.contains(c))
    }

    /// Whether the two peers speak the same protocol major version.
    pub fn version_compatible(&self, other: &Capabilities) -> bool {
        self.protocol_version == other.protocol_version
    }

    pub fn to_json(&self) -> Result<String, ProtocolError> {
        serde_json::to_string(self).map_err(|e| ProtocolError::Json(e.to_string()))
    }

    pub fn from_json(s: &str) -> Result<Self, ProtocolError> {
        serde_json::from_str(s).map_err(|e| ProtocolError::Json(e.to_string()))
    }
}

/// Errors from negotiation and (de)serialization.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("invalid config: {0}")]
    InvalidConfig(String),
    #[error("json error: {0}")]
    Json(String),
    #[error("protocol version mismatch: local {local}, remote {remote}")]
    VersionMismatch { local: u32, remote: u32 },
    #[error("no common codec")]
    NoCommonCodec,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_config_json_matches_existing_wire_format() {
        let cfg = DeviceConfig {
            width: 1920,
            height: 1080,
            refresh_rate: 60,
            codec: VideoCodec::Hevc,
            device_name: Some("Pixel".into()),
            platform: None,
            pairing_code: None,
        };
        let json = cfg.to_json().unwrap();
        // Field names must be exactly these (matches Swift Codable + Kotlin JSONObject).
        assert!(json.contains("\"width\":1920"));
        assert!(json.contains("\"height\":1080"));
        assert!(json.contains("\"refreshRate\":60"));
        assert!(json.contains("\"codec\":\"hevc\""));
        assert!(json.contains("\"deviceName\":\"Pixel\""));
        // Absent unless set, so sinks that predate pairing produce identical JSON.
        assert!(!json.contains("pairingCode"));
        assert!(!json.contains("platform"));
        let android = DeviceConfig { platform: Some(Platform::Android), ..cfg.clone() };
        assert!(android.to_json().unwrap().contains("\"platform\":\"android\""));
        // A platform name from the future parses as Unknown instead of failing the handshake.
        let future = DeviceConfig::from_json(r#"{"width":1,"height":1,"refreshRate":60,"platform":"visionos"}"#).unwrap();
        assert_eq!(future.platform, Some(Platform::Unknown));
        let paired = DeviceConfig { pairing_code: Some("123456".into()), ..cfg };
        assert!(paired.to_json().unwrap().contains("\"pairingCode\":\"123456\""));
    }

    #[test]
    fn device_config_parses_legacy_json_without_codec() {
        // Older clients may omit codec; must default to hevc.
        let json = r#"{"width":2960,"height":1848,"refreshRate":120}"#;
        let cfg = DeviceConfig::from_json(json).unwrap();
        assert_eq!(cfg.codec, VideoCodec::Hevc);
        assert_eq!(cfg.device_name, None);
    }

    #[test]
    fn device_config_omits_null_device_name() {
        let cfg = DeviceConfig::new(800, 600, 60, VideoCodec::H264);
        let json = cfg.to_json().unwrap();
        assert!(!json.contains("deviceName"));
        assert!(json.contains("\"codec\":\"h264\""));
    }

    #[test]
    fn validate_rejects_out_of_range() {
        assert!(DeviceConfig::new(1920, 1080, 60, VideoCodec::Hevc).validate().is_ok());
        assert!(DeviceConfig::new(0, 1080, 60, VideoCodec::Hevc).validate().is_err());
        assert!(DeviceConfig::new(1920, 1080, 500, VideoCodec::Hevc).validate().is_err());
        assert!(DeviceConfig::new(8000, 1080, 60, VideoCodec::Hevc).validate().is_err());
    }

    #[test]
    fn codec_negotiation_prefers_local_order() {
        let source = Capabilities {
            protocol_version: PROTOCOL_VERSION,
            role: Role::Source,
            platform: Platform::Windows,
            supported_codecs: vec![VideoCodec::Hevc, VideoCodec::H264],
            max_width: 3840,
            max_height: 2160,
            max_refresh_rate: 120,
        };
        // Sink only decodes H.264 → must fall back.
        let sink = Capabilities {
            protocol_version: PROTOCOL_VERSION,
            role: Role::Sink,
            platform: Platform::Android,
            supported_codecs: vec![VideoCodec::H264],
            max_width: 2400,
            max_height: 1080,
            max_refresh_rate: 90,
        };
        assert_eq!(source.negotiate_codec(&sink), Some(VideoCodec::H264));
        assert!(source.version_compatible(&sink));
    }

    #[test]
    fn codec_negotiation_returns_none_when_disjoint() {
        let a = Capabilities {
            protocol_version: PROTOCOL_VERSION,
            role: Role::Source,
            platform: Platform::Linux,
            supported_codecs: vec![VideoCodec::Av1],
            max_width: 3840,
            max_height: 2160,
            max_refresh_rate: 120,
        };
        let b = Capabilities {
            protocol_version: PROTOCOL_VERSION,
            role: Role::Sink,
            platform: Platform::Ios,
            supported_codecs: vec![VideoCodec::Hevc],
            max_width: 2778,
            max_height: 1284,
            max_refresh_rate: 120,
        };
        assert_eq!(a.negotiate_codec(&b), None);
    }
}
