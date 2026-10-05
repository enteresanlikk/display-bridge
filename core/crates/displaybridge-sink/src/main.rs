//! DisplayBridge sink for desktop Linux and Windows (it also runs on macOS).
//!
//! Turns this machine into a second monitor: it dials a DisplayBridge source, runs the
//! session through the shared core, and pipes the received H.265/H.264 stream into a
//! video player (`mpv`, else `ffplay`), which does the hardware decode and the window.
//! The player is a separate process on purpose: it already knows VAAPI, D3D11 and every
//! compositor, so this program has no platform code at all.
// ponytail: the player owns the window, so there is no input forwarding and no screen-size
// detection here. A native window (VAAPI / D3D11 + winit) is the upgrade when those matter.

use std::ffi::{c_char, c_void, CStr, CString};
use std::fs::File;
use std::io::Write;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Sender};
use std::sync::Mutex;

use displaybridge_ffi::{
    displaybridge_session_connect_tcp, displaybridge_session_create, displaybridge_session_destroy,
    displaybridge_session_set_config, displaybridge_session_set_pairing_code, DisplayBridgeCallbacks,
    DisplayBridgeDeviceConfig, DisplayBridgePlatform, DisplayBridgeRole, DisplayBridgeSessionState,
    DisplayBridgeVideoCodec,
};

const USAGE: &str = "\
Usage: displaybridge-sink --host <address> [options]

  --host <address>        The source to connect to (required)
  --port <number>         Source port (default: 7878)
  --pairing-code <code>   The pairing code shown on the source
  --width <px>            Width of the display to ask for (default: 1920)
  --height <px>           Height of the display to ask for (default: 1080)
  --refresh <hz>          Refresh rate to ask for (default: 60)
  --codec <hevc|h264>     Video codec (default: hevc)
  --name <text>           Name shown on the source (default: this program's platform)
  --player <command>      Player to pipe the stream into, reading it on stdin
                          (default: mpv, else ffplay, with low-latency settings)
  --output <file>         Write the raw stream to a file instead of playing it
  --help                  Show this help
";

#[derive(Debug, Clone, PartialEq)]
struct Args {
    host: String,
    port: u16,
    pairing_code: Option<String>,
    width: i32,
    height: i32,
    refresh: i32,
    hevc: bool,
    name: String,
    player: Option<String>,
    output: Option<String>,
}

fn parse_args(args: &[String]) -> Result<Args, String> {
    let mut a = Args {
        host: String::new(),
        port: 7878,
        pairing_code: None,
        width: 1920,
        height: 1080,
        refresh: 60,
        hevc: true,
        name: format!("{} sink", std::env::consts::OS),
        player: None,
        output: None,
    };
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        if flag == "--help" || flag == "-h" {
            return Err(String::new());
        }
        let value = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
        let number = || value.parse::<i32>().map_err(|_| format!("{flag}: '{value}' is not a number"));
        match flag.as_str() {
            "--host" => a.host = value.clone(),
            "--port" => a.port = value.parse().map_err(|_| format!("--port: '{value}' is not a port"))?,
            "--pairing-code" => a.pairing_code = Some(value.clone()),
            "--width" => a.width = number()?,
            "--height" => a.height = number()?,
            "--refresh" => a.refresh = number()?,
            "--codec" => match value.as_str() {
                "hevc" | "h265" => a.hevc = true,
                "h264" => a.hevc = false,
                _ => return Err(format!("--codec: '{value}' is not hevc or h264")),
            },
            "--name" => a.name = value.clone(),
            "--player" => a.player = Some(value.clone()),
            "--output" => a.output = Some(value.clone()),
            _ => return Err(format!("unknown option {flag}")),
        }
    }
    if a.host.is_empty() {
        return Err("--host is required".into());
    }
    Ok(a)
}

/// The players tried in order, each as (program, arguments). They read the raw stream on
/// stdin and are told to show every frame the moment it is decoded.
fn default_players(hevc: bool) -> Vec<(String, Vec<String>)> {
    let format = if hevc { "hevc" } else { "h264" };
    let owned = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    vec![
        (
            "mpv".into(),
            owned(&[
                "--profile=low-latency",
                "--untimed",
                "--no-cache",
                "--hwdec=auto-safe",
                &format!("--demuxer-lavf-format={format}"),
                "--demuxer-lavf-probesize=32",
                "--demuxer-lavf-analyzeduration=0",
                "--force-window=immediate",
                "--title=DisplayBridge",
                "--fs",
                "-",
            ]),
        ),
        (
            "ffplay".into(),
            owned(&[
                "-f", format, "-fflags", "nobuffer", "-flags", "low_delay", "-framedrop",
                "-probesize", "32", "-analyzeduration", "0", "-sync", "ext",
                "-window_title", "DisplayBridge", "-fs", "-i", "-",
            ]),
        ),
    ]
}

/// Starts the player and returns it with the pipe to feed.
fn spawn_player(args: &Args) -> Result<(Child, Box<dyn Write + Send>), String> {
    let candidates = match &args.player {
        Some(command) => {
            let mut parts = command.split_whitespace().map(str::to_string);
            let program = parts.next().ok_or("--player is empty")?;
            vec![(program, parts.collect())]
        }
        None => default_players(args.hevc),
    };
    let mut tried = Vec::new();
    for (program, arguments) in candidates {
        match Command::new(&program).args(&arguments).stdin(Stdio::piped()).spawn() {
            Ok(mut child) => {
                let stdin = child.stdin.take().ok_or("player has no stdin")?;
                eprintln!("[sink] playing through {program}");
                return Ok((child, Box::new(stdin)));
            }
            Err(e) => tried.push(format!("{program} ({e})")),
        }
    }
    Err(format!(
        "could not start a player: {}. Install mpv or ffplay, or pass --player / --output.",
        tried.join(", ")
    ))
}

enum Event {
    Streaming,
    Refused(String),
    Ended,
    PlayerClosed,
}

/// What the core's callbacks need. Shared with the core's reader thread.
struct Shared {
    stream: Mutex<Box<dyn Write + Send>>,
    events: Mutex<Sender<Event>>,
}

impl Shared {
    fn emit(&self, event: Event) {
        let _ = self.events.lock().unwrap().send(event);
    }
}

extern "C" fn on_frame(ctx: *mut c_void, nal: *const u8, len: usize, _key: bool, _ts: u64) {
    let shared = unsafe { &*(ctx as *const Shared) };
    let bytes = unsafe { std::slice::from_raw_parts(nal, len) };
    // A blocking write: a player that can't keep up slows the reader, TCP pushes back,
    // and the source skips frames instead of this side piling them up.
    let mut stream = shared.stream.lock().unwrap();
    if stream.write_all(bytes).and_then(|_| stream.flush()).is_err() {
        shared.emit(Event::PlayerClosed);
    }
}

extern "C" fn on_state(ctx: *mut c_void, state: DisplayBridgeSessionState) {
    let shared = unsafe { &*(ctx as *const Shared) };
    match state {
        DisplayBridgeSessionState::Streaming => shared.emit(Event::Streaming),
        DisplayBridgeSessionState::Disconnected => shared.emit(Event::Ended),
        _ => {}
    }
}

extern "C" fn on_error(ctx: *mut c_void, message: *const c_char) {
    let shared = unsafe { &*(ctx as *const Shared) };
    let message = unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned();
    shared.emit(Event::Refused(message));
}

fn run(args: &Args) -> Result<(), String> {
    let (mut player, stream): (Option<Child>, Box<dyn Write + Send>) = match &args.output {
        Some(path) => (None, Box::new(File::create(path).map_err(|e| format!("{path}: {e}"))?)),
        None => {
            let (child, stdin) = spawn_player(args)?;
            (Some(child), stdin)
        }
    };

    let (tx, rx) = mpsc::channel();
    let shared = Box::new(Shared { stream: Mutex::new(stream), events: Mutex::new(tx) });

    let callbacks = DisplayBridgeCallbacks {
        ctx: &*shared as *const Shared as *mut c_void,
        send: None, // the core owns the TCP socket
        reconfigure: None,
        start_capture: None,
        stop_capture: None,
        decode: Some(on_frame),
        on_state_change: Some(on_state),
        on_stats: None,
        on_input: None,
        on_error: Some(on_error),
    };
    let session = displaybridge_session_create(DisplayBridgeRole::Sink, callbacks);
    if session.is_null() {
        return Err("could not create the session".into());
    }

    let c_string = |s: &str| CString::new(s).map_err(|_| format!("'{s}' contains a NUL byte"));
    let name = c_string(&args.name)?;
    let host = c_string(&args.host)?;
    let config = DisplayBridgeDeviceConfig {
        width: args.width,
        height: args.height,
        refresh_rate: args.refresh,
        codec: if args.hevc { DisplayBridgeVideoCodec::Hevc } else { DisplayBridgeVideoCodec::H264 },
        device_name: name.as_ptr(),
        platform: DisplayBridgePlatform::Unknown,
    };

    // SAFETY: `session` is live until `displaybridge_session_destroy` below, every
    // pointer passed outlives its call, and `shared` outlives the session.
    let connected = unsafe {
        if let Some(code) = &args.pairing_code {
            let code = c_string(code)?;
            displaybridge_session_set_pairing_code(session, code.as_ptr());
        }
        displaybridge_session_set_config(session, &config)
            && displaybridge_session_connect_tcp(session, host.as_ptr(), args.port)
    };

    let result = if !connected {
        Err(format!("could not connect to {}:{}", args.host, args.port))
    } else {
        eprintln!(
            "[sink] connected to {}:{}, asking for {}x{}@{} {}",
            args.host, args.port, args.width, args.height, args.refresh,
            if args.hevc { "hevc" } else { "h264" }
        );
        let mut refusal = None;
        loop {
            match rx.recv() {
                Ok(Event::Streaming) => eprintln!("[sink] streaming"),
                Ok(Event::Refused(message)) => refusal = Some(message),
                Ok(Event::PlayerClosed) => break Ok(()),
                Ok(Event::Ended) | Err(_) => {
                    break match refusal.take() {
                        Some(message) => Err(format!("the source refused the connection: {message}")),
                        None => Ok(()),
                    }
                }
            }
        }
    };

    // SAFETY: the handle is live and not used again. This joins the core's threads, so
    // no callback can touch `shared` once it returns.
    unsafe { displaybridge_session_destroy(session) };
    drop(shared); // closes the player's stdin, which makes it exit
    if let Some(child) = player.as_mut() {
        let _ = child.wait();
    }
    result
}

fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let args = match parse_args(&raw) {
        Ok(args) => args,
        Err(message) => {
            if !message.is_empty() {
                eprintln!("{message}\n");
            }
            eprint!("{USAGE}");
            std::process::exit(if message.is_empty() { 0 } else { 2 });
        }
    };
    if let Err(message) = run(&args) {
        eprintln!("[sink] {message}");
        std::process::exit(1);
    }
    eprintln!("[sink] disconnected");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, String> {
        parse_args(&list.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn host_is_required_and_defaults_apply() {
        assert!(args(&[]).is_err());
        let a = args(&["--host", "10.0.0.5"]).unwrap();
        assert_eq!((a.host.as_str(), a.port), ("10.0.0.5", 7878));
        assert_eq!((a.width, a.height, a.refresh, a.hevc), (1920, 1080, 60, true));
        assert_eq!(a.pairing_code, None);
    }

    #[test]
    fn options_are_parsed_and_bad_ones_rejected() {
        let a = args(&[
            "--host", "mac.local", "--port", "9000", "--pairing-code", "123456", "--width", "2560",
            "--height", "1440", "--refresh", "120", "--codec", "h264", "--output", "out.h264",
        ])
        .unwrap();
        assert_eq!((a.port, a.width, a.height, a.refresh, a.hevc), (9000, 2560, 1440, 120, false));
        assert_eq!(a.pairing_code.as_deref(), Some("123456"));
        assert_eq!(a.output.as_deref(), Some("out.h264"));

        assert!(args(&["--host", "x", "--codec", "av1"]).is_err());
        assert!(args(&["--host", "x", "--port", "70000"]).is_err());
        assert!(args(&["--host", "x", "--width"]).is_err());
        assert!(args(&["--host", "x", "--frobnicate", "1"]).is_err());
    }

    #[test]
    fn players_are_told_the_codec() {
        let hevc = default_players(true);
        assert_eq!(hevc[0].0, "mpv");
        assert!(hevc[0].1.contains(&"--demuxer-lavf-format=hevc".to_string()));
        let h264 = default_players(false);
        assert!(h264[1].1.windows(2).any(|w| w[0] == "-f" && w[1] == "h264"));
    }
}
