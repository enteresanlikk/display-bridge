// Runnable, in-process proof of the Swift↔Rust FFI boundary (`swift run FFIProofRunner`).
//
// It drives the exact same scenarios as Tests/DisplayBridgeCoreTests/RustSessionFFITests.swift
// but as a plain executable that exits non-zero on any failure. It exists because the
// swift-testing tests, while correct (their test-content records are emitted), cannot be
// *executed* by `swift test` on a Command Line Tools-only install: there is no XCTest, and
// SwiftPM's swift-testing bundle host (the SIP-signed `swiftpm-testing-helper`) does not link
// Testing itself, so the bundle's tests register their image notifier too late to be
// discovered. This executable links Testing/DisplayBridgeCore at launch and runs the checks
// directly, giving a reproducible pass in this environment.
import Foundation
import DisplayBridgeCore

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  PASS: \(msg)") } else { print("  FAIL: \(msg)"); failures += 1 }
}

// Recorder
final class Rec: @unchecked Sendable {
    let lock = NSLock(); var packets: [Data] = []
    func add(_ d: Data) { lock.lock(); packets.append(d); lock.unlock() }
    func first(_ t: PacketType) -> (UInt64, UInt64, Data)? {
        lock.lock(); defer { lock.unlock() }
        for p in packets { if let x = try? PacketFramer.parsePacket(from: p), x.type == t { return (x.sequenceNumber, x.timestamp, Data(x.payload)) } }
        return nil
    }
}
final class B<T>: @unchecked Sendable { let l = NSLock(); var v: T; init(_ v: T){self.v=v}; func s(_ n:T){l.lock();v=n;l.unlock()}; var g:T{l.lock();defer{l.unlock()};return v} }

print("[source handshake -> frame round trip]")
let sends = Rec(); let reconf = B<DeviceConfig?>(nil); let started = B<DeviceConfig?>(nil); let streaming = B<Bool>(false)
let handlers = RustSessionHandlers(
    send: { sends.add($0) },
    reconfigure: { reconf.s($0) },
    startCapture: { started.s($0) },
    onStateChange: { if $0 == .streaming { streaming.s(true) } }
)
guard let src = RustSession(role: .source, handlers: handlers) else { print("FAIL: create source"); exit(2) }
let cfgJSON = #"{"width":1920,"height":1080,"refreshRate":60,"codec":"hevc"}"#
let hs = PacketFramer.createPacket(type: .handshakeReq, sequenceNumber: 1, timestamp: 1000, payload: Data(cfgJSON.utf8))
src.feed(bytes: hs)
let expected = DeviceConfig(width: 1920, height: 1080, refreshRate: 60, codec: .hevc)
check(reconf.g == expected, "reconfigure fired with 1920x1080@60 hevc")
check(started.g == expected, "start_capture fired with 1920x1080@60 hevc")
check(streaming.g, "state transitioned to .streaming")
if let ack = sends.first(.handshakeAck) {
    let echoed = try? JSONDecoder().decode(DeviceConfig.self, from: ack.2)
    check(echoed == expected, "HandshakeAck (0x02) emitted, echoes config")
} else { check(false, "HandshakeAck emitted") }
let nal = Data([0xDE,0xAD,0xBE,0xEF,0x00,0x01,0x02,0x03])
check(src.wantsFrame(), "streaming source asks for the next frame")
src.submitFrame(nal, isKeyframe: true, captureTimeNs: 12345)
// The frame leaves on the core's sender thread, not inside submitFrame.
let deadline = Date().addingTimeInterval(3)
while sends.first(.videoFrame) == nil && Date() < deadline { usleep(2000) }
if let v = sends.first(.videoFrame) {
    let p = v.2
    check(p.count >= 4 + nal.count, "VideoFrame payload length")
    check(p[p.startIndex] == 1, "keyframe flag set")
    check(Data(p[(p.startIndex+4)...]) == nal, "NAL bytes carried in VideoFrame (0x03)")
} else { check(false, "VideoFrame emitted via send") }
src.close()

print("[sink lifecycle + config marshalling]")
let sends2 = Rec()
guard let sink = RustSession(role: .sink, handlers: RustSessionHandlers(send: { sends2.add($0) })) else { print("FAIL: create sink"); exit(2) }
let ok = sink.setConfig(DeviceConfig(width: 1280, height: 720, refreshRate: 60, codec: .h264, deviceName: "Test Sink"))
check(ok, "setConfig across FFI succeeded (with device_name)")
sink.close(); sink.close()
check(true, "idempotent close did not crash")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
