# DisplayBridge on Linux

Turns a Linux machine into a second monitor for a Mac running DisplayBridge (sink
role). The program is `displaybridge-sink`, a small Rust binary on the shared core; it
hands the video to `mpv` (or `ffplay`), which does the hardware decode (VAAPI and
friends) and the window.

## Build and run

Needs Rust and `mpv` (`sudo apt install mpv`, `sudo dnf install mpv`, ...).

```bash
make sink        # or: cd core && cargo build --release -p displaybridge-sink
core/target/release/displaybridge-sink --host <mac-address> --pairing-code <code> \
    --width 1920 --height 1080 --refresh 60
```

`--width/--height/--refresh` are the display the Mac will create for this machine; set
them to your screen. `--help` lists the rest (`--codec h264`, `--player`, `--output`).

## Limits

- No input forwarding and no automatic discovery yet: the player owns the window.
- Sink only. Sharing a Linux desktop (source role) needs a virtual output and is not
  implemented.

Verified in a Debian container against a live Mac source: pairing, a stream recorded
and decoded without errors, and playback through `mpv`. Not yet tried on a desktop with
a real display.
