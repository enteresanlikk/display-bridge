# DisplayBridge

Turns another device into a second monitor for your Mac. Works over USB (AOA direct, Android) or the network. Targets <16ms end-to-end latency at native resolution using hardware H.265 encoding.

| Platform | Shares its display (source) | Acts as a monitor (sink) | Where |
|---|---|---|---|
| macOS | yes | yes | `platforms/apple` |
| Android | – | yes (USB or network, touch input) | `platforms/android` |
| iPhone / iPad | – | yes (network, touch input) — not yet built with Xcode | `platforms/ios` |
| Linux | – | yes (network, through `mpv`) | `platforms/linux` |
| Windows | – | yes (network, through `mpv`) — tested under Wine only | `platforms/windows` |

## Features

- **Touch, pen and mouse input** — tap, drag, two-finger scroll and two-finger tap (right click) on the tablet drive the Mac. Pen pressure and an attached mouse are passed through.
- **Pairing code** — a network client must enter the code shown on the Mac before it gets a picture or can send input. Five wrong codes lock new attempts out for a minute. USB needs no code. The pairing code can be changed in the app's window or with `--pairing-code` / `--new-pairing-code`.
- **Automatic discovery** — the Mac advertises itself over Bonjour; the Android app lists what it finds, so there is no IP to type.
- **Codec fallback** — a device without a hardware HEVC decoder asks for H.264 on its own.
- **Mac as a second monitor** — `DisplayBridgeSink` opens a window showing another Mac's extended display and sends mouse input back.

> The stream itself is not encrypted, and the pairing code travels in the clear: it keeps other devices on your network out, not someone who can already read your traffic. On a network you don't trust, use USB.

## Requirements

### macOS Server
- macOS 14+ (CGVirtualDisplay, ScreenCaptureKit)
- Swift 5.9+
- Screen Recording permission (System Settings > Privacy > Screen Recording)
- Accessibility permission (System Settings > Privacy & Security > Accessibility) for touch input; without it the picture works but taps do nothing

### Android Client
- Android 5.0+
- Hardware H.265 decode support

## Setup & Usage

### 1. Server (macOS)

```bash
make mac                       # Build the Rust core, then the CLI and the sink
make test                      # Rust tests + the headless end-to-end proofs

cd platforms/apple
swift run DisplayBridgeCLI     # Start in CLI mode (source); prints the pairing code
swift run DisplayBridgeApp     # Start as menu bar app
swift run DisplayBridgeSink --host <source-ip> --pairing-code <code>   # Run the Mac as a second monitor (sink)
```

> The Swift package links the shared Rust core (`core/`). `make core` rebuilds it and
> refreshes the C header the Swift side reads; run it after any change under `core/`.

#### CLI Options

| Option | Default | Description |
|---|---|---|
| `--width <px>` | 2960 | Virtual display width |
| `--height <px>` | 1848 | Virtual display height |
| `--refresh-rate <hz>` | 120 | Refresh rate |
| `--port <num>` | 7878 | TCP port |
| `--pairing-code <code>` | generated once, then kept | Set the code network clients must enter (saved) |
| `--new-pairing-code` | – | Replace the code with a new random one |
| `--no-pairing` | off | Accept any network client (trusted networks only) |
| `--max-bitrate <mbps>` | 50 over USB, up to 500 over network | Cap the video bitrate; it also adapts downward on its own when the link is slow |

```bash
# Example: 1920x1080 @60Hz on port 8080
swift run DisplayBridgeCLI --width 1920 --height 1080 --refresh-rate 60 --port 8080
```

### 2. Connection Methods

#### USB AOA (Direct — recommended)
Connect the Android device to Mac via USB. The server automatically detects the device and initiates AOA (Android Open Accessory) mode — no adb required.

#### USB via adb reverse (development only)
```bash
adb reverse tcp:7878 tcp:7878
```
Then open the Android client app and connect to `127.0.0.1:7878`. This method is primarily for development/debugging — use USB AOA for production.

#### Network
Open the Android client app: Macs running DisplayBridge on the same network appear in the list — tap one, enter the pairing code shown on the Mac, and connect. You can still type an IP address and port by hand.

Both TCP and USB AOA transports run simultaneously — multiple clients can connect via different methods at the same time.

## Project Structure

```
DisplayBridge/
├── core/                   # Shared Rust core (single source of truth), FFI to every platform
│   └── crates/
│       ├── displaybridge-protocol/    # wire framing, packet types, negotiation
│       ├── displaybridge-session/     # session state machine, pacing, metrics, heartbeat
│       ├── displaybridge-transport/   # portable TCP + USB-AOA host
│       ├── displaybridge-ffi/         # C ABI + generated header for native shells
│       └── displaybridge-sink/        # the Linux / Windows sink program
└── platforms/
    ├── apple/              # Swift package — macOS (source + sink), and the sink half of the iOS app
    │   ├── Package.swift
    │   └── Sources/        # CUSBKit, DisplayBridgeCore, CLI, App, DisplayBridgeSink, CDisplayBridgeFFI
    ├── android/            # Android client (Kotlin) — sink only
    ├── ios/                # iPhone / iPad app (Swift) — sink only, reuses the Apple package
    ├── linux/              # how to build and run the Rust sink on Linux
    └── windows/            # how to build and run the Rust sink on Windows
```

> **Roles.** A *source* extends/shares its display; a *sink* becomes a second monitor.
> macOS runs both; every other platform is sink-only for now.

## Pipeline

```
VirtualDisplay → ScreenCapturer (IOSurface) → VideoToolboxEncoder (H.265 HW)
    → PacketFramer (28B header + NAL) → Transport (TCP or USB AOA) → Android Client
```

## License

[MIT](LICENCE)
