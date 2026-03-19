// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DisplayBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DisplayBridgeCore", targets: ["DisplayBridgeCore"]),
        .executable(name: "DisplayBridgeCLI", targets: ["DisplayBridgeCLI"]),
        .executable(name: "DisplayBridgeApp", targets: ["DisplayBridgeApp"]),
    ],
    targets: [
        .target(
            name: "CUSBKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "DisplayBridgeCore",
            dependencies: ["CUSBKit"]
        ),
        .executableTarget(name: "DisplayBridgeCLI", dependencies: ["DisplayBridgeCore"]),
        .executableTarget(name: "DisplayBridgeApp", dependencies: ["DisplayBridgeCore"]),
    ]
)
