import CoreGraphics
import DisplayBridgeCore
import Foundation

// MARK: - Argument Parsing

struct CLIArguments {
    var width: Int = 2960
    var height: Int = 1848
    var refreshRate: Int = 120
    var host: String = "127.0.0.1"
    var port: UInt16 = 7878
    var pairingCode: String? = PairingCode.current()
    var maxBitrateMbps: Int?

    static func parse(_ args: [String]) -> CLIArguments {
        var result = CLIArguments()
        var i = 1 // skip executable name
        while i < args.count {
            switch args[i] {
            case "--width":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    result.width = val
                    i += 1
                }
            case "--height":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    result.height = val
                    i += 1
                }
            case "--refresh-rate":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    result.refreshRate = val
                    i += 1
                }
            case "--host":
                if i + 1 < args.count {
                    result.host = args[i + 1]
                    i += 1
                }
            case "--port":
                if i + 1 < args.count, let val = UInt16(args[i + 1]) {
                    result.port = val
                    i += 1
                }
            case "--pairing-code":
                if i + 1 < args.count, !args[i + 1].isEmpty {
                    result.pairingCode = args[i + 1]
                    i += 1
                }
            case "--max-bitrate":
                if i + 1 < args.count, let val = Int(args[i + 1]), val > 0 {
                    result.maxBitrateMbps = val
                    i += 1
                }
            case "--no-pairing":
                result.pairingCode = nil
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                print("Unknown argument: \(args[i])")
                printUsage()
                exit(1)
            }
            i += 1
        }
        return result
    }

    static func printUsage() {
        print("""
        DisplayBridge Server

        Usage: DisplayBridgeCLI [options]

        Options:
          --width <pixels>        Display width (default: 2960)
          --height <pixels>       Display height (default: 1848)
          --refresh-rate <hz>     Refresh rate (default: 120)
          --host <address>        Transport host (default: 127.0.0.1)
          --port <number>         Transport port (default: 7878)
          --pairing-code <code>   Code network clients must enter (default: generated once and kept)
          --no-pairing            Accept any network client without a code (trusted networks only)
          --max-bitrate <mbps>    Cap the video bitrate (default: 50 over USB, up to 500 over network)
          --help, -h              Show this help message
        """)
    }
}

// MARK: - Signal Handling

func installSignalHandler(_ handler: @escaping () -> Void) {
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
        handler()
    }
    signalSource.resume()

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signal(SIGTERM, SIG_IGN)
    termSource.setEventHandler {
        handler()
    }
    termSource.resume()

    // Keep sources alive by storing them
    withExtendedLifetime((signalSource, termSource)) {
        dispatchMain()
    }
}

// MARK: - Main

// Line-buffer stdout so the log is live when piped or redirected to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let args = CLIArguments.parse(CommandLine.arguments)

// Check screen recording permission before anything else
if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    print("Screen recording izni gerekli. System Settings > Privacy > Screen Recording'den izin verin.")
    print("İzin verdikten sonra uygulamayı yeniden başlatın.")
    exit(1)
}

print("DisplayBridge Server starting...")
print("  Resolution: \(args.width)x\(args.height)")
print("  Refresh rate: \(args.refreshRate) Hz")
print("  Transport: port \(args.port)")
print("  Pairing code: \(args.pairingCode ?? "disabled — any device on the network can connect and control this Mac")")
print("  Mode: Multi-client (each client gets its own virtual display)")

let config = DeviceConfig(
    width: args.width,
    height: args.height,
    refreshRate: args.refreshRate,
    codec: .hevc
)

let engine = ServerEngine(port: args.port)
engine.pairingCode = args.pairingCode
engine.maxBitrate = args.maxBitrateMbps.map { $0 * 1_000_000 }
// One line per client per second while frames flow: the numbers to look at when the
// picture stutters or lags.
engine.onClientStatsUpdated = { id, s in
    guard s.captureFPS > 0 else { return }
    print(String(
        format: "[Stats %@] capture %3.0f fps | sent %3.0f fps | dropped %2.0f%% | latency avg %5.1f max %5.1f ms | encode %4.1f ms | %4.0f KB/frame | %5.1f Mbps | link %3.0f%% busy",
        String(id.uuidString.prefix(8)), s.captureFPS, s.sentFPS, s.droppedPercent,
        s.avgLatencyMs, s.maxLatencyMs, s.encodeMs, s.frameKB, s.mbps, s.linkBusyPercent
    ))
}

Task {
    await engine.start(defaultConfig: config)
}

// Install signal handler to gracefully stop on SIGINT / SIGTERM
installSignalHandler {
    print("\nShutting down all clients...")
    Task {
        await engine.stop()
        print("Goodbye.")
        exit(0)
    }
}
