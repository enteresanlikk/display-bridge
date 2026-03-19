import CUSBKit
import Foundation

/// USB AOA bulk-endpoint transport implementing `DataTransporting`.
///
/// The Android f_accessory kernel driver uses a single-request sequential read model:
/// after each `read()` returns, there is a gap before the next `read()` queues a new
/// USB request. During this gap the device has NO pending request and will NAK the host.
///
/// To work around this:
/// - Uses `WritePipeTO` (with timeout) instead of `WritePipe` to detect NAK failures
///   instead of getting false success
/// - Sends data in chunks ≤ f_accessory's 16KB buffer (`BULK_BUFFER_SIZE`)
/// - Adds inter-frame delay after each complete send to let Android re-queue its request
/// - Uses chunk sizes that avoid USB Zero-Length Packet issues (not multiples of 512)
public final class AOATransport: @unchecked Sendable, DataTransporting {
    private let interface: CUSBInterfaceRef
    private let device: CUSBDeviceRef
    private let bulkInPipe: UInt8
    private let bulkOutPipe: UInt8
    private let lock = NSLock()

    /// Chunk size for USB writes. Must be ≤ f_accessory's BULK_BUFFER_SIZE (16384).
    /// Uses 16000 (not 16384) to avoid ZLP — 16384 is a multiple of 512.
    private static let maxChunkSize = 16000

    /// WritePipeTO timeout: abort if no data moves within this time (ms).
    /// Detects when device is persistently NAKing (no pending USB request).
    private static let noDataTimeoutMs: UInt32 = 1000

    /// WritePipeTO timeout: abort if entire chunk write exceeds this time (ms).
    private static let completionTimeoutMs: UInt32 = 5000

    /// Microseconds to wait after sending a complete frame, giving Android's
    /// f_accessory driver time to re-queue its USB read request.
    /// Reduced to 0 with the streaming buffer approach on Android — the read loop
    /// now reads large chunks (16384B) in a tight loop, minimizing the gap
    /// between USB requests. Previously 3ms, which added ~3ms per frame.
    private static let interFrameDelayUs: UInt32 = 0

    private var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var readThread: Thread?
    private var isDisconnected = false

    /// Serial queue for all USB bulk-out writes (control + video).
    private let writeQueue = DispatchQueue(label: "com.displaybridge.aoa-write", qos: .userInteractive)

    /// Counts total sendTracked calls for diagnostics.
    private var sendCount = 0

    /// Unique identifier for this AOA client session.
    public let clientID: UUID

    public init(interface: CUSBInterfaceRef, device: CUSBDeviceRef, bulkInPipe: UInt8, bulkOutPipe: UInt8, clientID: UUID = UUID()) {
        self.interface = interface
        self.device = device
        self.bulkInPipe = bulkInPipe
        self.bulkOutPipe = bulkOutPipe
        self.clientID = clientID
    }

    // MARK: - DataTransporting

    public func connect() async throws {}

    /// Synchronous bulk write for control packets (handshake, ping, etc.).
    public func send(_ data: Data) async throws {
        guard !lock.withLock({ isDisconnected }) else {
            throw USBTransportError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                guard !lock.withLock({ isDisconnected }) else {
                    continuation.resume(throwing: USBTransportError.notConnected)
                    return
                }
                do {
                    try writeChunked(data, label: "ctrl")
                    // Give Android time to process and re-queue USB request
                    if AOATransport.interFrameDelayUs > 0 { usleep(AOATransport.interFrameDelayUs) }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fire-and-forget send via the write queue.
    public func sendNonBlocking(_ data: Data) {
        sendTracked(data, onComplete: {})
    }

    /// Blocking bulk write with completion callback + inter-frame delay.
    public func sendTracked(_ data: Data, onComplete: @escaping @Sendable () -> Void) {
        guard !lock.withLock({ isDisconnected }) else {
            onComplete()
            return
        }

        guard data.count > 0 else {
            onComplete()
            return
        }

        writeQueue.async { [self] in
            defer { onComplete() }

            guard !lock.withLock({ isDisconnected }) else { return }

            sendCount += 1
            let currentSend = sendCount
            let verbose = currentSend <= 5

            let startNs = DispatchTime.now().uptimeNanoseconds

            do {
                let chunks = try writeChunked(data, label: verbose ? "send#\(currentSend)" : nil)

                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                if verbose || elapsedMs > 100 {
                    print(String(format: "[AOATransport] Send #%d OK: %dB in %d chunks (%.1fms)",
                                 currentSend, data.count, chunks, elapsedMs))
                }

                // CRITICAL: Wait after each frame so Android's f_accessory driver
                // has time to return from read() and re-queue its USB request.
                if AOATransport.interFrameDelayUs > 0 { usleep(AOATransport.interFrameDelayUs) }

            } catch {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                print("[AOATransport] Send #\(currentSend) FAILED: \(error) (\(String(format: "%.0f", elapsedMs))ms)")

                let cont: AsyncThrowingStream<Data, Error>.Continuation? = lock.withLock {
                    let c = receiveContinuation
                    receiveContinuation = nil
                    return c
                }
                cont?.finish(throwing: error)
            }
        }
    }

    // MARK: - Chunked Write with Timeout

    /// Sends data in chunks using WritePipeTO (with timeout detection).
    /// Returns the number of chunks written.
    @discardableResult
    private func writeChunked(_ data: Data, label: String?) throws -> Int {
        try data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else {
                throw USBTransportError.sendFailed("Empty data")
            }
            let total = data.count
            var offset = 0
            var chunksWritten = 0

            if let label {
                print("[AOATransport] \(label): \(total) bytes via pipe \(bulkOutPipe)")
            }

            while offset < total {
                let chunkLen = min(AOATransport.maxChunkSize, total - offset)
                let chunkPtr = basePtr.advanced(by: offset)

                let ret = CUSBWritePipeTO(
                    interface, bulkOutPipe,
                    UnsafeMutableRawPointer(mutating: chunkPtr),
                    UInt32(chunkLen),
                    AOATransport.noDataTimeoutMs,
                    AOATransport.completionTimeoutMs
                )

                guard ret == kIOReturnSuccess else {
                    let hexRet = String(format: "0x%X", ret)
                    print("[AOATransport] WritePipeTO FAILED at \(offset)/\(total): \(hexRet)")

                    throw USBTransportError.sendFailed(
                        "WritePipeTO failed at \(offset)/\(total): \(hexRet)"
                    )
                }

                chunksWritten += 1
                offset += chunkLen
            }

            return chunksWritten
        }
    }

    // MARK: - Receive

    public func receive() -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            self.lock.lock()
            self.receiveContinuation = continuation
            self.lock.unlock()

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.lock.lock()
                self?.receiveContinuation = nil
                self?.lock.unlock()
            }

            let thread = Thread {
                self.readLoop(continuation: continuation)
            }
            thread.name = "com.displaybridge.aoa-read"
            thread.qualityOfService = .userInteractive
            thread.start()
            self.readThread = thread
        }
    }

    /// ReadPipeTO timeout: release the IN pipe periodically so WritePipeTO
    /// on the OUT pipe can submit transfers without contention.
    private static let readTimeoutMs: UInt32 = 200

    private func readLoop(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        var buffer = Data()
        let chunkSize: UInt32 = 65536
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(chunkSize))
        defer { chunk.deallocate() }

        while !lock.withLock({ isDisconnected }) {
            var readLength = chunkSize
            let ret = CUSBReadPipeTO(
                interface, bulkInPipe, chunk, &readLength,
                AOATransport.readTimeoutMs,
                AOATransport.readTimeoutMs
            )

            if ret != kIOReturnSuccess {
                // Timeout is expected — just loop and retry.
                // This releases the IN pipe so OUT pipe writes can proceed.
                let isTimeout = (ret == Int32(bitPattern: 0xE0004051))  // kIOUSBTransactionTimeout
                             || (ret == Int32(bitPattern: 0xE00002ED))  // kIOReturnTimeout
                             || (ret == Int32(bitPattern: 0xE0004000))  // kIOUSBUnknownPipeErr (some drivers)
                if isTimeout {
                    continue
                }

                // kIOReturnAborted = pipe was aborted (disconnect in progress)
                if ret == Int32(bitPattern: 0xE00002EB) {
                    continuation.finish()
                    return
                }

                if !lock.withLock({ isDisconnected }) {
                    let hexRet = String(format: "0x%X", UInt32(bitPattern: ret))
                    print("[AOATransport] ReadPipeTO failed: \(hexRet)")
                    continuation.finish(throwing: USBTransportError.connectionFailed("ReadPipeTO failed: \(hexRet)"))
                } else {
                    continuation.finish()
                }
                return
            }

            if readLength > 0 {
                buffer.append(chunk, count: Int(readLength))
            }

            while buffer.count >= PacketFramer.headerSize {
                let lenStart = buffer.startIndex + 24
                let lenEnd = lenStart + 4
                let payloadLength = Int(
                    buffer[lenStart..<lenEnd]
                        .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                        .littleEndian
                )

                let totalPacketSize = PacketFramer.headerSize + payloadLength
                guard buffer.count >= totalPacketSize else {
                    break
                }

                let packet = Data(buffer.prefix(totalPacketSize))
                buffer.removeFirst(totalPacketSize)
                continuation.yield(packet)
            }
        }

        continuation.finish()
    }

    // MARK: - Disconnect

    public func disconnect() async {
        let alreadyDisconnected = lock.withLock {
            guard !isDisconnected else { return true }
            isDisconnected = true
            return false
        }
        guard !alreadyDisconnected else { return }

        CUSBAbortPipe(interface, bulkInPipe)
        CUSBAbortPipe(interface, bulkOutPipe)

        let cont: AsyncThrowingStream<Data, Error>.Continuation? = lock.withLock {
            let c = receiveContinuation
            receiveContinuation = nil
            return c
        }
        cont?.finish()

        CUSBInterfaceClose(interface)
        CUSBDeviceClose(device)
    }

    deinit {
        guard !isDisconnected else { return }
        CUSBAbortPipe(interface, bulkInPipe)
        CUSBAbortPipe(interface, bulkOutPipe)
        CUSBInterfaceClose(interface)
        CUSBDeviceClose(device)
    }
}
