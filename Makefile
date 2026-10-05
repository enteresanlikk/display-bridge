.PHONY: core mac test android android-install sink ios

# Swift links core/target/release and reads a hand-synced copy of the generated C header,
# so both must be refreshed whenever the Rust core changes. `make core` does both.
core:
	cd core && cargo build -p displaybridge-ffi --release
	cp core/crates/displaybridge-ffi/include/displaybridge_ffi.h platforms/apple/Sources/CDisplayBridgeFFI/include/

mac: core
	cd platforms/apple && swift build

test: core
	cd core && cargo test
	cd platforms/apple && swift run LiveSourceProof && swift run MacSinkProof && swift run FFIProofRunner && swift test

# Homebrew locations (brew install openjdk@17; brew install --cask android-commandlinetools
# android-platform-tools); override either variable if yours live elsewhere.
export JAVA_HOME ?= /opt/homebrew/opt/openjdk@17
export ANDROID_HOME ?= /opt/homebrew/share/android-commandlinetools

android:
	cd platforms/android && ./gradlew assembleDebug

# Needs a phone connected with USB debugging on.
android-install:
	cd platforms/android && ./gradlew installDebug

# The Linux / Windows sink (also runs on macOS). See platforms/linux and platforms/windows.
sink:
	cd core && cargo build --release -p displaybridge-sink

# Needs Xcode and XcodeGen. Then open platforms/ios/DisplayBridge.xcodeproj.
ios:
	platforms/ios/build-core.sh
	cd platforms/ios && xcodegen generate
