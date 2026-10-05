# DisplayBridge on Windows

Turns a Windows PC into a second monitor for a Mac running DisplayBridge (sink role).
The program is `displaybridge-sink.exe`, a small Rust binary on the shared core; it
hands the video to `mpv` (or `ffplay`), which does the hardware decode (D3D11) and the
window.

## Build and run

Needs Rust (<https://rustup.rs>) and `mpv` on the `PATH` (`winget install mpv`, or
`scoop install mpv`).

```powershell
cd core
cargo build --release -p displaybridge-sink
.\target\release\displaybridge-sink.exe --host <mac-address> --pairing-code <code> `
    --width 1920 --height 1080 --refresh 60
```

`--width/--height/--refresh` are the display the Mac will create for this PC; set them
to your screen. `--help` lists the rest (`--codec h264`, `--player`, `--output`).

## Limits

- No input forwarding and no automatic discovery yet: the player owns the window.
- Sink only. Sharing a Windows desktop (source role) needs a signed virtual-display
  driver and is not implemented.

The Windows build was cross-compiled and run under Wine against a live Mac source:
pairing and a recorded stream that decodes without errors. Not yet run on Windows
itself, and playback through `mpv.exe` is untried.
