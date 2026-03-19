# DisplayBridge

Turns an Android device into a second monitor for macOS. Works over USB (AOA direct) or TCP (Network / adb reverse). Targets <16ms end-to-end latency at native resolution using hardware H.265 encoding. Zero third-party dependencies.

## Requirements

### macOS Server
- macOS 14+ (CGVirtualDisplay, ScreenCaptureKit)
- Swift 5.9+
- Screen Recording permission (System Settings > Privacy > Screen Recording)

### Android Client
- Android 5.0+
- Hardware H.265 decode support

## Setup & Usage

### 1. Server (macOS)

```bash
cd servers/macos
swift build                    # Debug build
swift build -c release         # Release build
swift run DisplayBridgeCLI     # Start in CLI mode
swift run DisplayBridgeApp     # Start as menu bar app
```

#### CLI Options

| Option | Default | Description |
|---|---|---|
| `--width <px>` | 2960 | Virtual display width |
| `--height <px>` | 1848 | Virtual display height |
| `--refresh-rate <hz>` | 120 | Refresh rate |
| `--port <num>` | 7878 | TCP port |

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
Enter your Mac's IP address and port in the Android client app.

Both TCP and USB AOA transports run simultaneously — multiple clients can connect via different methods at the same time.

## Project Structure

```
DisplayBridge/
├── servers/
│   └── macos/              # macOS server (Swift, SPM)
│       ├── Package.swift
│       └── Sources/
│           ├── CUSBKit/           # IOKit USB C bridge
│           ├── DisplayBridgeCore/ # Core library (Clean Architecture)
│           ├── DisplayBridgeCLI/  # CLI app
│           └── DisplayBridgeApp/  # SwiftUI menu bar app
└── clients/
    └── android/            # Android client (Kotlin)
```

## Pipeline

```
VirtualDisplay → ScreenCapturer (IOSurface) → VideoToolboxEncoder (H.265 HW)
    → PacketFramer (28B header + NAL) → Transport (TCP or USB AOA) → Android Client
```

## License

[MIT](LICENCE)
