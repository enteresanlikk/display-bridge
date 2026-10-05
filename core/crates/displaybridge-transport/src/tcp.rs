//! Blocking TCP transport.
//!
//! Mirrors the Swift `ClientConnection` (per-client stream) and `ConnectionListener`
//! (accept loop) using `std::net` with blocking I/O and dedicated threads.
//!
//! The `adb reverse` / `127.0.0.1` path used on Android is just plain TCP, so it is
//! supported implicitly — dial `127.0.0.1:<port>` like any other address.

use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use displaybridge_protocol::PacketFramer;

use crate::{Transport, TransportError};

/// Size of a single `read` from the socket. Data is accumulated across reads and
/// reframed by [`PacketFramer::extract_packets`], so this only affects syscall
/// granularity, not packet boundaries.
const READ_CHUNK: usize = 64 * 1024;

/// A single blocking TCP connection implementing [`Transport`].
///
/// Construct either as a dialing client with [`TcpTransport::new`], or from a
/// stream handed over by [`TcpListenerTransport`] via [`TcpTransport::from_stream`].
pub struct TcpTransport {
    /// Address to dial on `connect` (client mode). `None` for accepted streams.
    dial_addr: Option<SocketAddr>,
    /// Pre-connected stream (server/accepted mode), consumed on `connect`.
    pending_stream: Option<TcpStream>,
    /// Shared write half, guarded by a mutex so concurrent senders serialize.
    write_stream: Option<Arc<Mutex<TcpStream>>>,

    on_packet: Option<Box<dyn FnMut(Vec<u8>) + Send>>,
    on_closed: Option<Box<dyn FnOnce() + Send>>,

    reader: Option<JoinHandle<()>>,
    started: bool,
}

impl TcpTransport {
    /// Creates a client transport that will dial `addr` on [`connect`](Transport::connect).
    pub fn new<A: ToSocketAddrs>(addr: A) -> Result<Self, TransportError> {
        let addr = addr
            .to_socket_addrs()
            .map_err(TransportError::Io)?
            .next()
            .ok_or_else(|| TransportError::ConnectionFailed("no address resolved".into()))?;
        Ok(Self {
            dial_addr: Some(addr),
            pending_stream: None,
            write_stream: None,
            on_packet: None,
            on_closed: None,
            reader: None,
            started: false,
        })
    }

    /// Wraps an already-connected stream (as produced by [`TcpListenerTransport`]).
    /// The reader thread starts when [`connect`](Transport::connect) is called.
    pub fn from_stream(stream: TcpStream) -> Self {
        Self {
            dial_addr: None,
            pending_stream: Some(stream),
            write_stream: None,
            on_packet: None,
            on_closed: None,
            reader: None,
            started: false,
        }
    }

    /// The peer address, if the connection has been established.
    pub fn peer_addr(&self) -> Option<SocketAddr> {
        self.pending_stream
            .as_ref()
            .and_then(|s| s.peer_addr().ok())
            .or_else(|| {
                self.write_stream
                    .as_ref()
                    .and_then(|s| s.lock().ok().and_then(|g| g.peer_addr().ok()))
            })
    }
}

/// Reader thread body: accumulate bytes, drain complete packets, deliver each one.
/// On EOF or error the loop exits and `on_closed` fires exactly once.
fn reader_loop(
    mut stream: TcpStream,
    mut on_packet: Option<Box<dyn FnMut(Vec<u8>) + Send>>,
    on_closed: Option<Box<dyn FnOnce() + Send>>,
) {
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = [0u8; READ_CHUNK];

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break, // EOF — peer closed.
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                if let Some(cb) = on_packet.as_mut() {
                    for packet in PacketFramer::extract_packets(&mut buffer) {
                        cb(packet);
                    }
                } else {
                    // No consumer registered; still drain so the buffer can't grow
                    // unbounded on a misconfigured transport.
                    PacketFramer::extract_packets(&mut buffer);
                }
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break, // Includes the shutdown triggered by `disconnect`.
        }
    }

    if let Some(cb) = on_closed {
        cb();
    }
}

impl Transport for TcpTransport {
    fn connect(&mut self) -> Result<(), TransportError> {
        if self.started {
            return Ok(());
        }

        let stream = if let Some(s) = self.pending_stream.take() {
            s
        } else if let Some(addr) = self.dial_addr {
            TcpStream::connect(addr)
                .map_err(|e| TransportError::ConnectionFailed(e.to_string()))?
        } else {
            return Err(TransportError::NotConnected);
        };

        // Low latency for interactive video/input, matching the Swift NWProtocolTCP
        // `noDelay = true` configuration.
        let _ = stream.set_nodelay(true);

        let read_half = stream.try_clone().map_err(TransportError::Io)?;
        self.write_stream = Some(Arc::new(Mutex::new(stream)));

        let on_packet = self.on_packet.take();
        let on_closed = self.on_closed.take();
        let handle = thread::Builder::new()
            .name("db-tcp-reader".into())
            .spawn(move || reader_loop(read_half, on_packet, on_closed))
            .map_err(TransportError::Io)?;
        self.reader = Some(handle);
        self.started = true;
        Ok(())
    }

    fn send(&mut self, data: &[u8]) -> Result<(), TransportError> {
        let ws = self
            .write_stream
            .as_ref()
            .ok_or(TransportError::NotConnected)?;
        let mut guard = ws
            .lock()
            .map_err(|_| TransportError::SendFailed("write lock poisoned".into()))?;
        guard
            .write_all(data)
            .map_err(|e| TransportError::SendFailed(e.to_string()))?;
        Ok(())
    }

    fn send_tracked(&mut self, data: Vec<u8>, on_complete: Box<dyn FnOnce() + Send>) {
        // For TCP, completion is "the blocking write returned". Doing it on the
        // caller's thread means a slow link throttles the producer directly.
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
        // Shutting the socket down unblocks the reader thread's blocking `read`,
        // which then exits and fires `on_closed`.
        if let Some(ws) = &self.write_stream {
            if let Ok(guard) = ws.lock() {
                let _ = guard.shutdown(Shutdown::Both);
            }
        }
    }
}

impl Drop for TcpTransport {
    fn drop(&mut self) {
        self.disconnect();
    }
}

/// Listens on a TCP port and hands each accepted client to a callback as a
/// (not-yet-started) [`TcpTransport`]. Mirrors the Swift `ConnectionListener`.
///
/// The callback should register its `on_packet` / `on_closed` handlers and then
/// call [`TcpTransport::connect`] to begin reading.
pub struct TcpListenerTransport {
    listener: TcpListener,
    stop: Arc<AtomicBool>,
    acceptor: Option<JoinHandle<()>>,
}

impl TcpListenerTransport {
    /// Binds a listener. Pass `127.0.0.1:0` for an ephemeral port (see
    /// [`local_addr`](TcpListenerTransport::local_addr)).
    pub fn bind<A: ToSocketAddrs>(addr: A) -> Result<Self, TransportError> {
        let listener = TcpListener::bind(addr)
            .map_err(|e| TransportError::ListenerFailed(e.to_string()))?;
        Ok(Self {
            listener,
            stop: Arc::new(AtomicBool::new(false)),
            acceptor: None,
        })
    }

    /// The address the listener is bound to (resolves the ephemeral port).
    pub fn local_addr(&self) -> Result<SocketAddr, TransportError> {
        self.listener.local_addr().map_err(TransportError::Io)
    }

    /// Starts a background accept loop. Each accepted connection is delivered to
    /// `on_client` as a fresh [`TcpTransport`] in `from_stream` mode.
    pub fn accept_loop(&mut self, mut on_client: Box<dyn FnMut(TcpTransport) + Send>) {
        // A clone shares the same underlying socket; set it non-blocking so the
        // accept loop can poll the stop flag for a clean shutdown.
        let listener = match self.listener.try_clone() {
            Ok(l) => l,
            Err(_) => return,
        };
        let _ = listener.set_nonblocking(true);
        let stop = self.stop.clone();

        let handle = thread::Builder::new()
            .name("db-tcp-acceptor".into())
            .spawn(move || loop {
                if stop.load(Ordering::Acquire) {
                    break;
                }
                match listener.accept() {
                    Ok((stream, _peer)) => {
                        // Hand a normal blocking stream to the transport.
                        let _ = stream.set_nonblocking(false);
                        on_client(TcpTransport::from_stream(stream));
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(20));
                    }
                    Err(_) => break,
                }
            })
            .ok();
        self.acceptor = handle;
    }

    /// Stops the accept loop and joins its thread.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.acceptor.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for TcpListenerTransport {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use displaybridge_protocol::PacketType;
    use std::sync::mpsc;

    /// Spins up a listener, accepts exactly one client, and returns the server-side
    /// transport plus a receiver of packets it decodes.
    fn start_pair() -> (TcpTransport, TcpTransport, mpsc::Receiver<Vec<u8>>, mpsc::Receiver<Vec<u8>>)
    {
        let mut listener = TcpListenerTransport::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();

        // Server side: the accept callback configures and starts one transport,
        // then publishes it back to this thread over a channel.
        let (server_tx, server_rx) = mpsc::channel();
        let (srv_pkt_tx, srv_pkt_rx) = mpsc::channel();
        listener.accept_loop(Box::new(move |mut t: TcpTransport| {
            let pkt_tx = srv_pkt_tx.clone();
            t.set_on_packet(Box::new(move |p| {
                let _ = pkt_tx.send(p);
            }));
            t.connect().unwrap();
            let _ = server_tx.send(t);
        }));

        // Client side.
        let (cli_pkt_tx, cli_pkt_rx) = mpsc::channel();
        let mut client = TcpTransport::new(addr).unwrap();
        client.set_on_packet(Box::new(move |p| {
            let _ = cli_pkt_tx.send(p);
        }));
        client.connect().unwrap();

        let server = server_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("server accepted a client");

        // Keep the listener alive for the duration of the test by leaking it into
        // the returned closure's environment is unnecessary; drop is fine here
        // because the connection is already established.
        drop(listener);

        (client, server, srv_pkt_rx, cli_pkt_rx)
    }

    fn recv(rx: &mpsc::Receiver<Vec<u8>>) -> Vec<u8> {
        rx.recv_timeout(Duration::from_secs(2))
            .expect("packet within timeout")
    }

    #[test]
    fn packets_flow_in_both_directions() {
        let (mut client, mut server, srv_rx, cli_rx) = start_pair();

        let a = PacketFramer::create_packet(PacketType::HandshakeReq, 1, 10, b"hello");
        let b = PacketFramer::create_packet(PacketType::Ping, 2, 20, b"");
        client.send(&a).unwrap();
        client.send(&b).unwrap();
        assert_eq!(recv(&srv_rx), a);
        assert_eq!(recv(&srv_rx), b);

        let c = PacketFramer::create_packet(PacketType::HandshakeAck, 3, 30, b"world!!");
        server.send(&c).unwrap();
        assert_eq!(recv(&cli_rx), c);

        client.disconnect();
        server.disconnect();
    }

    #[test]
    fn coalesced_write_reframes_into_two_packets() {
        let (mut client, mut server, srv_rx, _cli_rx) = start_pair();

        let a = PacketFramer::create_packet(PacketType::VideoFrame, 1, 1, b"aaaa");
        let b = PacketFramer::create_packet(PacketType::VideoFrame, 2, 2, b"bbbbbbbb");
        // Two packets in a single write.
        let mut both = a.clone();
        both.extend_from_slice(&b);
        client.send(&both).unwrap();

        assert_eq!(recv(&srv_rx), a);
        assert_eq!(recv(&srv_rx), b);

        client.disconnect();
        server.disconnect();
    }

    #[test]
    fn split_write_reassembles_single_packet() {
        let (mut client, mut server, srv_rx, _cli_rx) = start_pair();

        let pkt = PacketFramer::create_packet(PacketType::ConfigUpdate, 7, 7, b"a-longer-payload");
        let split = pkt.len() / 2;
        // Send the packet split across two writes with a gap, so the reader must
        // hold the partial packet in its buffer until the rest arrives.
        client.send(&pkt[..split]).unwrap();
        thread::sleep(Duration::from_millis(50));
        client.send(&pkt[split..]).unwrap();

        assert_eq!(recv(&srv_rx), pkt);

        client.disconnect();
        server.disconnect();
    }

    #[test]
    fn on_closed_fires_when_peer_disconnects() {
        // Build a pair by hand so the server transport can register an on_closed
        // callback before connecting.
        let mut listener = TcpListenerTransport::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();

        let (server_tx, server_rx) = mpsc::channel();
        let (closed_tx, closed_rx) = mpsc::channel();
        listener.accept_loop(Box::new(move |mut t: TcpTransport| {
            let closed_tx = closed_tx.clone();
            t.set_on_closed(Box::new(move || {
                let _ = closed_tx.send(());
            }));
            t.connect().unwrap();
            let _ = server_tx.send(t);
        }));

        let mut client = TcpTransport::new(addr).unwrap();
        client.connect().unwrap();
        let _server = server_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        // Closing the client makes the server's reader hit EOF and fire on_closed.
        client.disconnect();
        closed_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("server on_closed fired after client disconnect");
    }
}
