#!/bin/sh
# Builds the Rust core for iPhone/iPad and for the simulator, and packs both into the
# xcframework the Xcode project links. Run again after any change under core/.
set -eu
cd "$(dirname "$0")"
CORE=../../core
OUT=build/DisplayBridgeFFI.xcframework

# Apple-silicon simulator only; add x86_64-apple-ios (and lipo it with the sim slice) to
# run the simulator on an Intel Mac.
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
    rustup target add "$target" >/dev/null
    # staticlib only: the crate's cdylib flavour cannot be linked without an app around it.
    (cd "$CORE" && cargo rustc -p displaybridge-ffi --release --target "$target" --crate-type staticlib)
done

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "The Rust core is built, but packing it for Xcode needs Xcode itself" >&2
    echo "(install it, then: sudo xcode-select -s /Applications/Xcode.app)." >&2
    exit 1
fi

rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$CORE/target/aarch64-apple-ios/release/libdisplaybridge_ffi.a" \
    -library "$CORE/target/aarch64-apple-ios-sim/release/libdisplaybridge_ffi.a" \
    -output "$OUT"
