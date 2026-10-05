//! Build script: regenerates the C header (`include/displaybridge_ffi.h`) from the crate's
//! `#[repr(C)]` / `extern "C"` surface on every `cargo build`, so the header the
//! platform shells consume can never drift from the Rust source.

use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR set by cargo");
    let out_dir = PathBuf::from(&crate_dir).join("include");
    let out_file = out_dir.join("displaybridge_ffi.h");

    // Regenerate when the sources or the cbindgen config change.
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");

    if let Err(e) = std::fs::create_dir_all(&out_dir) {
        println!("cargo:warning=displaybridge-ffi: could not create include dir: {e}");
        return;
    }

    match cbindgen::generate(&crate_dir) {
        Ok(bindings) => {
            bindings.write_to_file(&out_file);
        }
        Err(e) => {
            // Don't fail the build if header generation hiccups (e.g. a transient
            // parse issue); surface it as a warning so the compile still succeeds.
            println!("cargo:warning=displaybridge-ffi: cbindgen header generation failed: {e}");
        }
    }
}
