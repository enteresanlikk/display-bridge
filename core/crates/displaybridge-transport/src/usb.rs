//! USB Android Open Accessory (AOA) host transport, built on `rusb`/libusb.
//!
//! This is the portable reimplementation of the Swift `AOAManager` (device
//! discovery + AOA negotiation over IOKit) and `AOATransport` (bulk-endpoint
//! streaming). The whole module is gated behind the `usb` cargo feature so the
//! crate builds without libusb installed.
//!
//! ## Learned constraints (preserved from the Swift/Kotlin implementations)
//!
//! - **The 150 Mbps encoder cap belongs on the *source*, not here.** This transport
//!   moves whatever bytes it is handed; rate limiting is a producer concern. Do not
//!   add throttling in this module.
//! - **Read in chunks matching the Android kernel `f_accessory` `BULK_BUFFER_SIZE`
//!   (16384).** The device's driver services one read request at a time; reading in
//!   16 KiB chunks in a tight loop minimizes the gap between USB requests.
//! - **Writes are chunked to `MAX_CHUNK` (< 16384) to stay under the device buffer
//!   and avoid zero-length-packet edge cases** (16384 is a multiple of 512).
//! - **Disconnects are explicit protocol packets** (`PacketType::Disconnect`), not
//!   inferred from bus events. Physical removal surfaces as a bulk-transfer error,
//!   which ends the reader loop.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use rusb::{request_type, Direction, GlobalContext, Recipient, RequestType, TransferType};

use displaybridge_protocol::PacketFramer;

use crate::{Transport, TransportError};

// ---- AOA protocol constants (must match Android's accessory_filter.xml) ----

/// Google's vendor ID, used by devices already in AOA mode.
const AOA_VENDOR_ID: u16 = 0x18D1;
/// Product IDs a device presents once it has entered AOA / AOA+ADB mode.
const AOA_PRODUCT_IDS: [u16; 2] = [0x2D00, 0x2D01];

/// AOA control request: query the supported protocol version (device-to-host).
const AOA_GET_PROTOCOL: u8 = 51; // 0x33
/// AOA control request: send an identity string (host-to-device).
const AOA_SEND_STRING: u8 = 52; // 0x34
/// AOA control request: start accessory mode (host-to-device).
const AOA_START: u8 = 53; // 0x35

/// Accessory identity strings. These must match `accessory_filter.xml` on Android
/// so the phone offers DisplayBridge as the handling app. Copied byte-for-byte from
/// the Swift `AOAManager`.
const ID_MANUFACTURER: &str = "DisplayBridge";
const ID_MODEL: &str = "DisplayBridge";
const ID_DESCRIPTION: &str = "DisplayBridge Virtual Display";
const ID_VERSION: &str = "1.0";
const ID_URI: &str = "https://github.com/enteresanlikk/display-bridge";
const ID_SERIAL: &str = "1";

/// Kernel `f_accessory` bulk buffer size — read granularity for the IN endpoint.
const BULK_BUFFER_SIZE: usize = 16384;

/// Max write chunk. Kept below `BULK_BUFFER_SIZE` and off 512-byte multiples to
/// avoid zero-length-packet issues, matching the Swift `maxChunkSize`.
const MAX_CHUNK: usize = 16000;

/// Timeout for control transfers during negotiation.
const CONTROL_TIMEOUT: Duration = Duration::from_millis(1000);
/// Timeout for a single bulk write chunk.
const WRITE_TIMEOUT: Duration = Duration::from_millis(5000);
/// Timeout for a single bulk read. Short so `disconnect` is observed promptly
/// (the loop re-checks its stop flag every timeout).
const READ_TIMEOUT: Duration = Duration::from_millis(200);

type Handle = rusb::DeviceHandle<GlobalContext>;

/// Discovers an Android device, performs AOA negotiation if needed, opens the
/// accessory interface, and returns a ready [`UsbAoaTransport`].
///
/// Because a device *re-enumerates* after negotiation (it disappears and comes back
/// with an AOA product ID), a single call cannot both negotiate and open. Callers
/// should invoke this in a retry loop with a short delay: the first pass kicks off
/// negotiation and returns [`TransportError::NotConnected`]; a later pass finds the
/// re-enumerated accessory and opens it.
pub fn find_aoa_transport() -> Result<UsbAoaTransport, TransportError> {
    let devices = rusb::devices().map_err(|e| TransportError::ConnectionFailed(e.to_string()))?;

    // First pass: is a device already in AOA mode? If so, open it.
    for device in devices.iter() {
        let desc = match device.device_descriptor() {
            Ok(d) => d,
            Err(_) => continue,
        };
        if desc.vendor_id() == AOA_VENDOR_ID && AOA_PRODUCT_IDS.contains(&desc.product_id()) {
            return open_accessory(&device);
        }
    }

    // Second pass: nothing in AOA mode yet — try to negotiate the first device that
    // responds to the AOA protocol query. It will re-enumerate; the caller retries.
    for device in devices.iter() {
        if desc_is_aoa(&device) {
            continue;
        }
        let handle = match device.open() {
            Ok(h) => h,
            Err(_) => continue, // e.g. ADB holds the device; skip.
        };
        if negotiate(&handle).is_ok() {
            return Err(TransportError::NotConnected); // Re-enumerating; retry.
        }
    }

    Err(TransportError::NotConnected)
}

fn desc_is_aoa(device: &rusb::Device<GlobalContext>) -> bool {
    match device.device_descriptor() {
        Ok(d) => d.vendor_id() == AOA_VENDOR_ID && AOA_PRODUCT_IDS.contains(&d.product_id()),
        Err(_) => false,
    }
}

/// Runs the AOA handshake: check protocol version, push identity strings, start
/// accessory mode. On success the device re-enumerates with an AOA product ID.
fn negotiate(handle: &Handle) -> Result<(), TransportError> {
    // Step 1: protocol version (device-to-host, vendor, device).
    let in_type = request_type(Direction::In, RequestType::Vendor, Recipient::Device);
    let mut version_buf = [0u8; 2];
    let n = handle
        .read_control(in_type, AOA_GET_PROTOCOL, 0, 0, &mut version_buf, CONTROL_TIMEOUT)
        .map_err(|e| TransportError::ConnectionFailed(format!("AOA getProtocol: {e}")))?;
    if n < 2 {
        return Err(TransportError::ConnectionFailed("AOA getProtocol short read".into()));
    }
    let version = u16::from_le_bytes(version_buf);
    if version < 1 {
        return Err(TransportError::ConnectionFailed(format!(
            "device does not support AOA (version={version})"
        )));
    }

    // Step 2: identity strings (host-to-device, vendor, device), null-terminated.
    let out_type = request_type(Direction::Out, RequestType::Vendor, Recipient::Device);
    let strings: [(u16, &str); 6] = [
        (0, ID_MANUFACTURER),
        (1, ID_MODEL),
        (2, ID_DESCRIPTION),
        (3, ID_VERSION),
        (4, ID_URI),
        (5, ID_SERIAL),
    ];
    for (index, value) in strings {
        let mut bytes = value.as_bytes().to_vec();
        bytes.push(0); // null terminator
        handle
            .write_control(out_type, AOA_SEND_STRING, 0, index, &bytes, CONTROL_TIMEOUT)
            .map_err(|e| {
                TransportError::ConnectionFailed(format!("AOA sendString[{index}]: {e}"))
            })?;
    }

    // Step 3: start accessory mode. The device re-enumerates after this.
    handle
        .write_control(out_type, AOA_START, 0, 0, &[], CONTROL_TIMEOUT)
        .map_err(|e| TransportError::ConnectionFailed(format!("AOA start: {e}")))?;
    Ok(())
}

/// Opens a device that is already in AOA mode: claims its interface and locates the
/// bulk IN/OUT endpoints.
fn open_accessory(device: &rusb::Device<GlobalContext>) -> Result<UsbAoaTransport, TransportError> {
    let config = device
        .config_descriptor(0)
        .map_err(|e| TransportError::ConnectionFailed(format!("config descriptor: {e}")))?;

    let mut iface_number: Option<u8> = None;
    let mut bulk_in: Option<u8> = None;
    let mut bulk_out: Option<u8> = None;

    for interface in config.interfaces() {
        for descriptor in interface.descriptors() {
            for endpoint in descriptor.endpoint_descriptors() {
                if endpoint.transfer_type() != TransferType::Bulk {
                    continue;
                }
                match endpoint.direction() {
                    Direction::In => bulk_in = Some(endpoint.address()),
                    Direction::Out => bulk_out = Some(endpoint.address()),
                }
                if bulk_in.is_some() || bulk_out.is_some() {
                    iface_number = Some(interface.number());
                }
            }
        }
        if bulk_in.is_some() && bulk_out.is_some() {
            break;
        }
    }

    let iface = iface_number
        .ok_or_else(|| TransportError::ConnectionFailed("no bulk interface".into()))?;
    let bulk_in =
        bulk_in.ok_or_else(|| TransportError::ConnectionFailed("no bulk IN endpoint".into()))?;
    let bulk_out =
        bulk_out.ok_or_else(|| TransportError::ConnectionFailed("no bulk OUT endpoint".into()))?;

    let handle = device
        .open()
        .map_err(|e| TransportError::ConnectionFailed(format!("open: {e}")))?;

    Ok(UsbAoaTransport {
        handle: Arc::new(handle),
        iface,
        bulk_in,
        bulk_out,
        write_lock: Arc::new(Mutex::new(())),
        on_packet: None,
        on_closed: None,
        reader: None,
        closed: Arc::new(AtomicBool::new(false)),
        started: false,
    })
}

/// USB AOA bulk-endpoint transport implementing [`Transport`].
///
/// Mirrors the Swift `AOATransport`: a dedicated reader thread pulls 16 KiB chunks
/// from the bulk IN endpoint and reframes them with [`PacketFramer::extract_packets`],
/// while writes are chunked over the bulk OUT endpoint under a serializing lock.
pub struct UsbAoaTransport {
    handle: Arc<Handle>,
    iface: u8,
    bulk_in: u8,
    bulk_out: u8,
    /// Serializes bulk-out writes (control + video), like the Swift write queue.
    write_lock: Arc<Mutex<()>>,

    on_packet: Option<Box<dyn FnMut(Vec<u8>) + Send>>,
    on_closed: Option<Box<dyn FnOnce() + Send>>,

    reader: Option<JoinHandle<()>>,
    closed: Arc<AtomicBool>,
    started: bool,
}

impl UsbAoaTransport {
    /// The libusb interface number claimed for bulk transfers.
    pub fn interface_number(&self) -> u8 {
        self.iface
    }
}

/// Reader thread: read 16 KiB chunks, accumulate, drain complete packets, deliver
/// each one. Exits on error/disconnect and fires `on_closed` exactly once.
fn reader_loop(
    handle: Arc<Handle>,
    bulk_in: u8,
    closed: Arc<AtomicBool>,
    mut on_packet: Option<Box<dyn FnMut(Vec<u8>) + Send>>,
    on_closed: Option<Box<dyn FnOnce() + Send>>,
) {
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = [0u8; BULK_BUFFER_SIZE];

    while !closed.load(Ordering::Acquire) {
        match handle.read_bulk(bulk_in, &mut chunk, READ_TIMEOUT) {
            Ok(0) => continue,
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                if let Some(cb) = on_packet.as_mut() {
                    for packet in PacketFramer::extract_packets(&mut buffer) {
                        cb(packet);
                    }
                } else {
                    PacketFramer::extract_packets(&mut buffer);
                }
            }
            // Timeout is expected: it lets the loop re-check `closed` and releases
            // the IN pipe so OUT writes aren't starved.
            Err(rusb::Error::Timeout) => continue,
            Err(_) => break,
        }
    }

    if let Some(cb) = on_closed {
        cb();
    }
}

impl Transport for UsbAoaTransport {
    fn connect(&mut self) -> Result<(), TransportError> {
        if self.started {
            return Ok(());
        }
        // Detach any kernel driver so we can claim the interface, then claim it.
        let _ = self.handle.set_auto_detach_kernel_driver(true);
        self.handle
            .claim_interface(self.iface)
            .map_err(|e| TransportError::ConnectionFailed(format!("claim interface: {e}")))?;

        let handle = self.handle.clone();
        let bulk_in = self.bulk_in;
        let closed = self.closed.clone();
        let on_packet = self.on_packet.take();
        let on_closed = self.on_closed.take();
        let reader = thread::Builder::new()
            .name("db-usb-reader".into())
            .spawn(move || reader_loop(handle, bulk_in, closed, on_packet, on_closed))
            .map_err(TransportError::Io)?;
        self.reader = Some(reader);
        self.started = true;
        Ok(())
    }

    fn send(&mut self, data: &[u8]) -> Result<(), TransportError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(TransportError::NotConnected);
        }
        let _guard = self
            .write_lock
            .lock()
            .map_err(|_| TransportError::SendFailed("write lock poisoned".into()))?;

        // Chunk to stay under the device buffer.
        let mut offset = 0;
        while offset < data.len() {
            let end = (offset + MAX_CHUNK).min(data.len());
            let written = self
                .handle
                .write_bulk(self.bulk_out, &data[offset..end], WRITE_TIMEOUT)
                .map_err(|e| TransportError::SendFailed(format!("write_bulk: {e}")))?;
            if written == 0 {
                return Err(TransportError::SendFailed("write_bulk wrote 0 bytes".into()));
            }
            offset += written;
        }
        Ok(())
    }

    fn send_tracked(&mut self, data: Vec<u8>, on_complete: Box<dyn FnOnce() + Send>) {
        // Blocking write provides natural backpressure; fire completion once done.
        let _ = self.send(&data);
        on_complete();
    }

    fn set_on_packet(&mut self, cb: Box<dyn FnMut(Vec<u8>) + Send>) {
        self.on_packet = Some(cb);
    }

    fn set_on_closed(&mut self, cb: Box<dyn FnOnce() + Send>) {
        self.on_closed = Some(cb);
    }

    fn disconnect(&mut self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        // The reader loop observes `closed` on its next timeout tick and exits,
        // then releases the interface via this handle's Drop.
        let _ = self.handle.release_interface(self.iface);
    }
}

impl Drop for UsbAoaTransport {
    fn drop(&mut self) {
        self.disconnect();
    }
}
