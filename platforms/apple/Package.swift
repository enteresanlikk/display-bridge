// swift-tools-version: 6.0
import PackageDescription
import Foundation

// --- swift-testing wiring for a Command Line Tools-only install ---------------
// A full Xcode toolchain provides swift-testing (and XCTest) on the default search
// paths, so `swift test` works with no extra flags. A Command Line Tools-only install
// ships swift-testing under an Xcode-style Frameworks directory that is NOT on the
// default search path, so the test target needs explicit -F / -rpath flags to compile
// and link `import Testing`. We add those flags ONLY when Xcode is absent and the CLT
// Testing.framework is present, so a full-Xcode machine is left untouched.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let needsCLTSwiftTesting =
    !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
    && FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
// The @Test / #expect macros expand through a compiler plugin that the CLT keeps in a
// directory the compiler does not search by default.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = needsCLTSwiftTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-plugin-path", cltTestingPlugins])]
    : []
let testTestingLinkerFlags: [String] = needsCLTSwiftTesting
    ? [
        "-F", cltFrameworks,
        // Runtime search paths so dyld can load Testing.framework and its
        // lib_TestingInterop.dylib dependency from the Command Line Tools.
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltTestingLib,
      ]
    : []

// Linker flags for the DisplayBridge Rust core static library.
//   -L path is relative to the package root (platforms/apple) → ../../core/target/release
//   -ldisplaybridge_ffi links crates/displaybridge-ffi's cdylib/staticlib output.
//   The system libs the staticlib needs come from:
//     cargo rustc -p displaybridge-ffi --release --crate-type staticlib -- \
//       --print native-static-libs
//   which reports: -lSystem -lc -lm  (all satisfied by libSystem on macOS,
//   listed explicitly here for clarity / future portability).
let rustCoreLinkerFlags: [String] = [
    "-L../../core/target/release",
    "-ldisplaybridge_ffi",
    "-lSystem",
    "-lc",
    "-lm",
]

let package = Package(
    name: "DisplayBridge",
    // tools-version is 6.0 so `swift test` discovers/runs swift-testing tests
    // (the active Command Line Tools ships swift-testing, not XCTest). The language
    // mode is pinned to v5 (see swiftLanguageModes below) so the existing targets
    // keep compiling unchanged (6.0 would otherwise default to the stricter Swift 6
    // language mode).
    // iOS builds only DisplayBridgeCore, and of it only the sink side (the source-side
    // files are wrapped in `#if os(macOS)`); see platforms/ios.
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "DisplayBridgeCore", targets: ["DisplayBridgeCore"]),
        .executable(name: "DisplayBridgeCLI", targets: ["DisplayBridgeCLI"]),
        .executable(name: "DisplayBridgeApp", targets: ["DisplayBridgeApp"]),
        .executable(name: "DisplayBridgeSink", targets: ["DisplayBridgeSink"]),
    ],
    targets: [
        .target(
            name: "CUSBKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Surfaces the Rust core's cbindgen-generated C ABI header as a Swift module.
        // The header under include/ is a verbatim copy of the canonical
        // core/crates/displaybridge-ffi/include/displaybridge_ffi.h (see its banner).
        .target(
            name: "CDisplayBridgeFFI"
        ),
        .target(
            name: "DisplayBridgeCore",
            dependencies: [
                .target(name: "CUSBKit", condition: .when(platforms: [.macOS])),
                "CDisplayBridgeFFI",
            ],
            linkerSettings: [
                // macOS links the Rust core from core/target; the iOS app links it from the
                // xcframework that platforms/ios/build-core.sh assembles.
                .unsafeFlags(rustCoreLinkerFlags, .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "DisplayBridgeCLI",
            dependencies: ["DisplayBridgeCore"],
            linkerSettings: [
                .unsafeFlags(rustCoreLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "DisplayBridgeApp",
            dependencies: ["DisplayBridgeCore"],
            linkerSettings: [
                .unsafeFlags(rustCoreLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "FFIProofRunner",
            dependencies: ["DisplayBridgeCore"],
            linkerSettings: [
                .unsafeFlags(rustCoreLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "LiveSourceProof",
            dependencies: ["DisplayBridgeCore"],
            linkerSettings: [
                .unsafeFlags(rustCoreLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "DisplayBridgeSink",
            dependencies: ["DisplayBridgeCore"],
            linkerSettings: [
                .unsafeFlags(rustCoreLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "MacSinkProof",
            dependencies: ["DisplayBridgeCore"],
            linkerSettings: [
                .unsafeFlags(rustCoreLinkerFlags)
            ]
        ),
        .testTarget(
            name: "DisplayBridgeCoreTests",
            dependencies: ["DisplayBridgeCore", "CDisplayBridgeFFI"],
            swiftSettings: testSwiftSettings,
            linkerSettings: [
                .unsafeFlags(rustCoreLinkerFlags + testTestingLinkerFlags)
            ]
        ),
    ],
    // Keep the existing targets in Swift 5 language mode under tools-version 6.0.
    swiftLanguageModes: [.v5]
)
