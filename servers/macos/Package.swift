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
        .target(name: "DisplayBridgeCore"),
        .executableTarget(name: "DisplayBridgeCLI", dependencies: ["DisplayBridgeCore"]),
        .executableTarget(name: "DisplayBridgeApp", dependencies: ["DisplayBridgeCore"]),
    ]
)
