//! DisplayBridge transports — the portable transport layer shared by all desktop
//! platforms.
//!
//! This crate replaces the platform-specific Swift transports (`ClientConnection`,
//! `ConnectionListener`, `AOATransport`, `AOAManager`) with a single blocking,
//! thread-based implementation. There is **no async runtime** — every transport
//! spawns a dedicated OS reader thread and delivers complete packets through a
//! callback. Writes are blocking, which provides natural backpressure.
//!
//! Two transports are provided:
//! - [`TcpTransport`] / [`TcpListenerTransport`] — always available.
//! - [`usb::UsbAoaTransport`] — behind the `usb` cargo feature (needs `rusb`/libusb).
//!
//! All framing goes through [`displaybridge_protocol::PacketFramer`]: reader threads accumulate
//! raw bytes and call `extract_packets` so a single `read` is never assumed to be a
//! single packet.

use thiserror::Error;

mod tcp;
#[cfg(feature = "usb")]
pub mod usb;

pub use tcp::{TcpListenerTransport, TcpTransport};

/// Errors surfaced by a [`Transport`].
#[derive(Debug, Error)]
pub enum TransportError {
    /// Establishing the connection failed (dial/open/negotiation).
    #[error("connection failed: {0}")]
    ConnectionFailed(String),

    /// A write did not complete.
    #[error("send failed: {0}")]
    SendFailed(String),

    /// The transport is not connected (no active stream/handle).
    #[error("not connected")]
    NotConnected,

    /// Binding or accepting on a listener failed.
    #[error("listener failed: {0}")]
    ListenerFailed(String),

    /// A lower-level I/O error.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// A blocking, thread-based bidirectional packet transport.
///
/// # Lifecycle
/// 1. Construct the concrete transport.
/// 2. Register callbacks with [`set_on_packet`](Transport::set_on_packet) and
///    [`set_on_closed`](Transport::set_on_closed). These **must** be set before
///    [`connect`](Transport::connect), because `connect` moves them into the
///    dedicated reader thread.
/// 3. Call [`connect`](Transport::connect) to start the reader thread (and, for a
///    dialing client, to establish the connection).
/// 4. Use [`send`](Transport::send) / [`send_tracked`](Transport::send_tracked).
/// 5. Call [`disconnect`](Transport::disconnect) to tear everything down.
///
/// Received data is delivered one *complete packet* at a time via the `on_packet`
/// callback. When the connection ends — peer close, I/O error, or a local
/// `disconnect` — the `on_closed` callback fires exactly once.
pub trait Transport {
    /// Establishes the connection (dials for a client, no-op for an already
    /// accepted stream) and starts the reader thread.
    fn connect(&mut self) -> Result<(), TransportError>;

    /// Blocking write of a complete, already-framed packet (or several).
    /// Returns once the bytes have been handed to the OS.
    fn send(&mut self, data: &[u8]) -> Result<(), TransportError>;

    /// Blocking write with a completion callback used for backpressure tracking.
    ///
    /// `on_complete` fires once the write has been accepted — for TCP that is
    /// right after the blocking write returns. Because the write blocks the
    /// caller, this naturally throttles a producer to the link speed.
    fn send_tracked(&mut self, data: Vec<u8>, on_complete: Box<dyn FnOnce() + Send>);

    /// Registers the per-packet callback. Each call receives exactly one complete
    /// packet (header + payload). Must be set before [`connect`](Transport::connect).
    fn set_on_packet(&mut self, cb: Box<dyn FnMut(Vec<u8>) + Send>);

    /// Registers the connection-closed callback, fired exactly once when the
    /// connection ends. Must be set before [`connect`](Transport::connect).
    fn set_on_closed(&mut self, cb: Box<dyn FnOnce() + Send>);

    /// Tears down the connection and unblocks the reader thread.
    fn disconnect(&mut self);
}
