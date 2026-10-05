//! The C ABI entry points.
//!
//! Every exported function is `extern "C"` + `#[no_mangle]`, null-checks all
//! pointers, and wraps any body that could panic in `catch_unwind` so a panic never
//! unwinds across the FFI boundary (which would be undefined behaviour). Handles are
//! opaque; the only way to free one is [`displaybridge_session_destroy`].

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::sync::Arc;

use crate::driver::Driver;
use crate::types::{
    DisplayBridgeCallbacks, DisplayBridgeDeviceConfig, DisplayBridgeInputEvent, DisplayBridgeRole,
};

/// Opaque session handle returned by [`displaybridge_session_create`]. Native code only ever
/// holds a `*mut DisplayBridgeSession` and passes it back to the other entry points.
pub struct DisplayBridgeSession {
    driver: Arc<Driver>,
}

/// Creates a session driver for `role`, wiring in the native callback vtable.
///
/// Spawns the background clock thread. Returns an opaque handle, or null on failure.
/// The handle must be released with [`displaybridge_session_destroy`]; nothing else frees it.
#[no_mangle]
pub extern "C" fn displaybridge_session_create(role: DisplayBridgeRole, callbacks: DisplayBridgeCallbacks) -> *mut DisplayBridgeSession {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let driver = Driver::create(role.into(), callbacks);
        Box::into_raw(Box::new(DisplayBridgeSession { driver }))
    }));
    result.unwrap_or(std::ptr::null_mut())
}

/// Sets the display config a sink advertises in its `HandshakeReq`.
///
/// Call on a sink session before [`displaybridge_session_connect_tcp`]. Ignored for a source
/// (which learns the config from the incoming handshake). Returns `false` if either
/// pointer is null.
///
/// # Safety
/// `handle` must be a live handle from [`displaybridge_session_create`]; `config` (and its
/// `device_name`, if set) must be valid for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_set_config(
    handle: *mut DisplayBridgeSession,
    config: *const DisplayBridgeDeviceConfig,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return false;
        };
        let Some(config) = config.as_ref() else {
            return false;
        };
        session.driver.set_config(config.to_device_config());
        true
    }))
    .unwrap_or(false)
}

/// Sets the pairing code. On a source, every sink must then present this code in its
/// handshake or be refused; on a sink, it is the code presented. Call before
/// connecting. Returns `false` on a null handle, or a null / empty / non-UTF-8 code.
///
/// # Safety
/// `handle` must be a live handle; `code` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_set_pairing_code(
    handle: *mut DisplayBridgeSession,
    code: *const c_char,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return false;
        };
        if code.is_null() {
            return false;
        }
        match CStr::from_ptr(code).to_str() {
            Ok(code) if !code.is_empty() => {
                session.driver.set_pairing_code(code.to_owned());
                true
            }
            _ => false,
        }
    }))
    .unwrap_or(false)
}

/// Convenience for network shells: builds a Rust-owned TCP transport, wires it to the
/// driver, dials `host:port`, and feeds a `Connected` event.
///
/// A sink additionally sends its `HandshakeReq` here (set its config first). Returns
/// `false` on a null handle/host or any connection failure.
///
/// # Safety
/// `handle` must be a live handle; `host` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_connect_tcp(
    handle: *mut DisplayBridgeSession,
    host: *const c_char,
    port: u16,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return false;
        };
        if host.is_null() {
            return false;
        }
        let Ok(host) = CStr::from_ptr(host).to_str() else {
            return false;
        };
        session.driver.connect_tcp(host, port)
    }))
    .unwrap_or(false)
}

/// Reads the core's process-global monotonic clock, in nanoseconds.
///
/// Native code should stamp a frame's capture time with this (and pass it to
/// [`displaybridge_session_submit_frame`] as `capture_time_ns`) so the driver's
/// send-latency measurement shares one epoch with the capture timestamp. Mixing a
/// platform clock (e.g. Apple `DispatchTime` uptime) with the core's clock makes
/// `now - capture` underflow and report zero latency. Safe to call anytime.
#[no_mangle]
pub extern "C" fn displaybridge_monotonic_ns() -> u64 {
    crate::driver::monotonic_ns()
}

/// Signals that a native-owned transport has connected.
///
/// The native-owned-transport counterpart of the `Connected` event that
/// [`displaybridge_session_connect_tcp`] feeds automatically: it drives the machine to
/// `Negotiating` and, for a sink, sends the opening `HandshakeReq` (set its config
/// first). Call exactly once, after the native transport is ready and before feeding
/// bytes. Do NOT call it when using the built-in Rust transport. No-op on a null handle.
///
/// # Safety
/// `handle` must be a live handle from [`displaybridge_session_create`].
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_notify_connected(handle: *mut DisplayBridgeSession) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return;
        };
        session.driver.notify_connected();
    }));
}

/// Feeds bytes received on a native-owned transport (Android USB) into the driver.
///
/// The driver buffers, reframes with the shared packet framer, and processes each
/// complete packet. No-op on a null handle or null/empty buffer.
///
/// # Safety
/// `handle` must be a live handle; `data` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_feed_bytes(
    handle: *mut DisplayBridgeSession,
    data: *const u8,
    len: usize,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return;
        };
        if data.is_null() || len == 0 {
            return;
        }
        let bytes = slice::from_raw_parts(data, len);
        session.driver.feed_bytes(bytes);
    }));
}

/// Source data plane: asks whether the frame just captured should be encoded at all.
///
/// Call this before encoding each captured frame and skip the frame on `false` (not
/// streaming, or the previous frame has not reached the wire yet). Skipping before the
/// encoder keeps its reference chain intact; dropping an already encoded frame would
/// corrupt the picture until the next keyframe. Returns `false` on a null handle.
///
/// # Safety
/// `handle` must be a live handle from [`displaybridge_session_create`].
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_wants_frame(handle: *mut DisplayBridgeSession) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return false;
        };
        session.driver.wants_frame()
    }))
    .unwrap_or(false)
}

/// Source data plane: hands an already hardware-encoded frame to the driver.
///
/// The driver frames it as a `VideoFrame` and queues it for its sender thread, which
/// writes it to the active transport and records metrics; this call does not block on
/// the write. No-op on a null
/// handle or null/empty buffer, or if the session is not streaming.
///
/// # Safety
/// `handle` must be a live handle; `encoded` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_submit_frame(
    handle: *mut DisplayBridgeSession,
    encoded: *const u8,
    len: usize,
    is_keyframe: bool,
    capture_time_ns: u64,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return;
        };
        if encoded.is_null() || len == 0 {
            return;
        }
        let bytes = slice::from_raw_parts(encoded, len);
        session
            .driver
            .submit_frame(bytes, is_keyframe, capture_time_ns);
    }));
}

/// Sink input plane: forwards a pointer event to the source, which injects it into
/// the display it is sharing.
///
/// Returns `false` on a null handle, an unknown `event.kind`, a session that is not a
/// streaming sink, or a failed write.
///
/// # Safety
/// `handle` must be a live handle from [`displaybridge_session_create`].
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_send_input(
    handle: *mut DisplayBridgeSession,
    event: DisplayBridgeInputEvent,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = handle.as_ref() else {
            return false;
        };
        let Some(event) = event.to_input_event() else {
            return false;
        };
        session.driver.send_input(&event)
    }))
    .unwrap_or(false)
}

/// Stops the driver's threads, disconnects the transport, and frees the handle.
///
/// After this returns the handle is invalid and must not be used again. No-op on null.
///
/// # Safety
/// `handle` must be a live handle from [`displaybridge_session_create`] that has not already been
/// destroyed.
#[no_mangle]
pub unsafe extern "C" fn displaybridge_session_destroy(handle: *mut DisplayBridgeSession) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return;
        }
        // Reclaim ownership of the box, shut down, then drop.
        let session = Box::from_raw(handle);
        session.driver.shutdown();
        drop(session);
    }));
}
