# DisplayBridge

Turns an Android device into a second monitor for macOS. Works over TCP via USB cable. Targets <8ms end-to-end latency at native resolution using hardware H.265 encoding.

## Requirements

### macOS Server
- macOS 13+ (ScreenCaptureKit)
- macOS 14+ (CGVirtualDisplay — virtual display)
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

### 2. Android Connection

Connect the Android device to Mac via USB and set up adb port forwarding:

```bash
adb reverse tcp:7878 tcp:7878
```

Then open the Android client app — it will connect automatically.

### 3. WiFi Connection (alternative)

You can also connect over WiFi without adb. Enter your Mac's IP address and port in the Android client.

## Project Structure

```
DisplayBridge/
├── servers/
│   └── macos/          # macOS server (Swift, SPM)
│       ├── Package.swift
│       └── Sources/
│           ├── DisplayBridgeCore/    # Core library
│           ├── DisplayBridgeCLI/     # CLI app
│           └── DisplayBridgeApp/     # Menu bar app
└── clients/
    └── android/        # Android client (Kotlin)
```

## Pipeline

```
VirtualDisplay → ScreenCapturer (IOSurface) → VideoToolboxEncoder (H.265 HW)
    → PacketFramer (28B header + NAL) → TCP Transport → Android Client
```
