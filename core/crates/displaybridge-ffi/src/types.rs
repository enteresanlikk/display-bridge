//! C ABI data types shared across the FFI boundary.
//!
//! Every type here is `#[repr(C)]` (or a `#[repr(u32)]` enum) so its layout is
//! stable and cbindgen can emit a matching C declaration. Conversions to/from the
//! pure `displaybridge-protocol` / `displaybridge-session` types live here so the rest of the crate can
//! work in native Rust terms.

use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;

use displaybridge_protocol::{DeviceConfig, InputEvent, InputKind, Platform, Role, VideoCodec};
use displaybridge_session::{ClientStats, SessionState};

/// The role this session plays, mirroring `displaybridge_protocol::Role`.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayBridgeRole {
    /// Owns and captures a display; encodes and sends frames. (server)
    Source = 0,
    /// Receives frames, decodes and renders them. (client)
    Sink = 1,
}

impl From<DisplayBridgeRole> for Role {
    fn from(r: DisplayBridgeRole) -> Self {
        match r {
            DisplayBridgeRole::Source => Role::Source,
            DisplayBridgeRole::Sink => Role::Sink,
        }
    }
}

/// The video codec, mirroring `displaybridge_protocol::VideoCodec`.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayBridgeVideoCodec {
    /// H.265 / HEVC.
    Hevc = 0,
    /// H.264 / AVC.
    H264 = 1,
    /// AV1 (reserved; not negotiated yet).
    Av1 = 2,
}

impl From<DisplayBridgeVideoCodec> for VideoCodec {
    fn from(c: DisplayBridgeVideoCodec) -> Self {
        match c {
            DisplayBridgeVideoCodec::Hevc => VideoCodec::Hevc,
            DisplayBridgeVideoCodec::H264 => VideoCodec::H264,
            DisplayBridgeVideoCodec::Av1 => VideoCodec::Av1,
        }
    }
}

impl From<VideoCodec> for DisplayBridgeVideoCodec {
    fn from(c: VideoCodec) -> Self {
        match c {
            VideoCodec::Hevc => DisplayBridgeVideoCodec::Hevc,
            VideoCodec::H264 => DisplayBridgeVideoCodec::H264,
            VideoCodec::Av1 => DisplayBridgeVideoCodec::Av1,
        }
    }
}

/// What a sink runs on, mirroring `displaybridge_protocol::Platform`. `Unknown` is zero,
/// so a zeroed config struct says "unknown".
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayBridgePlatform {
    Unknown = 0,
    Macos = 1,
    Windows = 2,
    Linux = 3,
    Android = 4,
    Ios = 5,
    Ipados = 6,
}

impl From<Platform> for DisplayBridgePlatform {
    fn from(p: Platform) -> Self {
        match p {
            Platform::Macos => DisplayBridgePlatform::Macos,
            Platform::Windows => DisplayBridgePlatform::Windows,
            Platform::Linux => DisplayBridgePlatform::Linux,
            Platform::Android => DisplayBridgePlatform::Android,
            Platform::Ios => DisplayBridgePlatform::Ios,
            Platform::Ipados => DisplayBridgePlatform::Ipados,
            Platform::Unknown => DisplayBridgePlatform::Unknown,
        }
    }
}

impl From<DisplayBridgePlatform> for Option<Platform> {
    fn from(p: DisplayBridgePlatform) -> Self {
        Some(match p {
            DisplayBridgePlatform::Unknown => return None,
            DisplayBridgePlatform::Macos => Platform::Macos,
            DisplayBridgePlatform::Windows => Platform::Windows,
            DisplayBridgePlatform::Linux => Platform::Linux,
            DisplayBridgePlatform::Android => Platform::Android,
            DisplayBridgePlatform::Ios => Platform::Ios,
            DisplayBridgePlatform::Ipados => Platform::Ipados,
        })
    }
}

/// Observable session lifecycle state, mirroring `displaybridge_session::SessionState`.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayBridgeSessionState {
    /// No session yet.
    Idle = 0,
    /// The transport is being established.
    Connecting = 1,
    /// Connected; negotiating the handshake.
    Negotiating = 2,
    /// Handshake complete; frames are flowing.
    Streaming = 3,
    /// The session has ended.
    Disconnected = 4,
}

impl From<SessionState> for DisplayBridgeSessionState {
    fn from(s: SessionState) -> Self {
        match s {
            SessionState::Idle => DisplayBridgeSessionState::Idle,
            SessionState::Connecting => DisplayBridgeSessionState::Connecting,
            SessionState::Negotiating => DisplayBridgeSessionState::Negotiating,
            SessionState::Streaming => DisplayBridgeSessionState::Streaming,
            SessionState::Disconnected => DisplayBridgeSessionState::Disconnected,
        }
    }
}

/// A display configuration passed across the boundary.
///
/// `device_name` is a NUL-terminated UTF-8 C string and may be null.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct DisplayBridgeDeviceConfig {
    /// Display width in pixels.
    pub width: i32,
    /// Display height in pixels.
    pub height: i32,
    /// Refresh rate in Hz.
    pub refresh_rate: i32,
    /// The negotiated / requested codec.
    pub codec: DisplayBridgeVideoCodec,
    /// Optional human-readable device name (nullable, NUL-terminated UTF-8).
    pub device_name: *const c_char,
    /// What the sink runs on. A sink may leave it `Unknown`: the core then fills in the
    /// platform it was compiled for. A source reads it to label the client.
    pub platform: DisplayBridgePlatform,
}

impl DisplayBridgeDeviceConfig {
    /// Converts to a `displaybridge_protocol::DeviceConfig`.
    ///
    /// # Safety
    /// `self.device_name`, if non-null, must point to a valid NUL-terminated string
    /// that stays alive for the duration of this call.
    pub unsafe fn to_device_config(&self) -> DeviceConfig {
        let device_name = if self.device_name.is_null() {
            None
        } else {
            CStr::from_ptr(self.device_name)
                .to_str()
                .ok()
                .map(|s| s.to_owned())
        };
        DeviceConfig {
            width: self.width,
            height: self.height,
            refresh_rate: self.refresh_rate,
            codec: self.codec.into(),
            device_name,
            platform: self.platform.into(),
            pairing_code: None,
        }
    }
}

/// Lightweight per-interval pipeline stats, mirroring `displaybridge_session::ClientStats`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct DisplayBridgeClientStats {
    /// Frames captured per second.
    pub capture_fps: f64,
    /// Frames sent per second.
    pub sent_fps: f64,
    /// Percentage of captured frames dropped.
    pub dropped_percent: f64,
    /// Average send latency in milliseconds.
    pub avg_latency_ms: f64,
    /// Peak send latency in milliseconds.
    pub max_latency_ms: f64,
}

impl From<ClientStats> for DisplayBridgeClientStats {
    fn from(c: ClientStats) -> Self {
        DisplayBridgeClientStats {
            capture_fps: c.capture_fps,
            sent_fps: c.sent_fps,
            dropped_percent: c.dropped_percent,
            avg_latency_ms: c.avg_latency_ms,
            max_latency_ms: c.max_latency_ms,
        }
    }
}

/// A pointer event, mirroring `displaybridge_protocol::InputEvent`.
///
/// `kind` is a raw byte rather than an enum so an out-of-range value coming from
/// native code is rejected instead of being undefined behaviour:
/// 0 down, 1 move, 2 up, 3 scroll, 4 hover.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct DisplayBridgeInputEvent {
    /// 0 down, 1 move, 2 up, 3 scroll, 4 hover.
    pub kind: u8,
    /// 0 primary, 1 secondary.
    pub button: u8,
    /// Position, 0..1 across the display width.
    pub x: f32,
    /// Position, 0..1 down the display height.
    pub y: f32,
    /// Scroll delta as a fraction of the display width.
    pub dx: f32,
    /// Scroll delta as a fraction of the display height.
    pub dy: f32,
    /// Pressure, 0..1 (1.0 for a plain touch or click).
    pub pressure: f32,
}

impl DisplayBridgeInputEvent {
    /// Converts to the protocol type; `None` if `kind` is not a known value.
    pub fn to_input_event(self) -> Option<InputEvent> {
        Some(InputEvent {
            kind: InputKind::from_u8(self.kind)?,
            button: self.button,
            x: self.x,
            y: self.y,
            dx: self.dx,
            dy: self.dy,
            pressure: self.pressure,
        })
    }
}

impl From<InputEvent> for DisplayBridgeInputEvent {
    fn from(e: InputEvent) -> Self {
        DisplayBridgeInputEvent {
            kind: e.kind as u8,
            button: e.button,
            x: e.x,
            y: e.y,
            dx: e.dx,
            dy: e.dy,
            pressure: e.pressure,
        }
    }
}

/// Native callback vtable, supplied at session creation.
///
/// `ctx` is an opaque pointer handed back to every callback; the native side owns
/// its lifetime and thread-safety. Any function pointer may be null — the driver
/// null-checks before calling. The driver invokes these from its internal reader
/// and clock threads, so the native `ctx` and callbacks must be thread-safe.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct DisplayBridgeCallbacks {
    /// Opaque context pointer passed to every callback.
    pub ctx: *mut c_void,

    /// Write already-framed bytes to a native-owned transport (Android USB path).
    /// Null when the built-in Rust transport (`displaybridge_session_connect_tcp`) is used.
    pub send: Option<extern "C" fn(ctx: *mut c_void, data: *const u8, len: usize)>,

    /// Source hook: (re)build the capture/encode pipeline for `config`.
    pub reconfigure: Option<extern "C" fn(ctx: *mut c_void, config: *const DisplayBridgeDeviceConfig)>,

    /// Source hook: start capturing/encoding for `config`.
    pub start_capture: Option<extern "C" fn(ctx: *mut c_void, config: *const DisplayBridgeDeviceConfig)>,

    /// Source hook: stop the current capture.
    pub stop_capture: Option<extern "C" fn(ctx: *mut c_void)>,

    /// Sink hook: deliver a decoded-ready NAL unit to the native decoder.
    pub decode: Option<
        extern "C" fn(
            ctx: *mut c_void,
            nal: *const u8,
            len: usize,
            is_keyframe: bool,
            timestamp_micros: u64,
        ),
    >,

    /// Optional: observe session state transitions.
    pub on_state_change: Option<extern "C" fn(ctx: *mut c_void, state: DisplayBridgeSessionState)>,

    /// Optional: receive periodic pipeline stats (source only).
    pub on_stats: Option<extern "C" fn(ctx: *mut c_void, stats: DisplayBridgeClientStats)>,

    /// Source hook: a pointer event arrived from the sink; inject it into the display.
    pub on_input: Option<extern "C" fn(ctx: *mut c_void, event: DisplayBridgeInputEvent)>,

    /// Optional: the peer refused the session (e.g. a wrong pairing code). `message`
    /// is NUL-terminated UTF-8 meant for the user, valid only during the call.
    pub on_error: Option<extern "C" fn(ctx: *mut c_void, message: *const c_char)>,
}

/// Send/Sync wrapper around the raw callback vtable.
///
/// The raw `ctx` pointer makes `DisplayBridgeCallbacks` neither `Send` nor `Sync` by default;
/// the native contract is that `ctx` and every callback are safe to invoke from the
/// driver's background threads, which this asserts.
pub(crate) struct SafeCallbacks(pub DisplayBridgeCallbacks);

// SAFETY: upheld by the FFI contract — the native side guarantees `ctx` and the
// callbacks are thread-safe (see `DisplayBridgeCallbacks` docs).
unsafe impl Send for SafeCallbacks {}
unsafe impl Sync for SafeCallbacks {}

impl SafeCallbacks {
    /// The opaque native context.
    #[inline]
    pub fn ctx(&self) -> *mut c_void {
        self.0.ctx
    }

    /// Invokes a config-carrying callback (`reconfigure` / `start_capture`),
    /// building a temporary `DisplayBridgeDeviceConfig` (and backing `CString`) that lives for
    /// the duration of the call.
    pub fn call_with_config(
        &self,
        cb: Option<extern "C" fn(*mut c_void, *const DisplayBridgeDeviceConfig)>,
        config: &DeviceConfig,
    ) {
        let Some(cb) = cb else { return };
        // Keep the CString alive until after the call returns.
        let cname = config
            .device_name
            .as_ref()
            .and_then(|s| CString::new(s.as_str()).ok());
        let db_config = DisplayBridgeDeviceConfig {
            width: config.width,
            height: config.height,
            refresh_rate: config.refresh_rate,
            codec: config.codec.into(),
            device_name: cname.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            platform: config.platform.map_or(DisplayBridgePlatform::Unknown, Into::into),
        };
        cb(self.0.ctx, &db_config);
        drop(cname);
    }
}
