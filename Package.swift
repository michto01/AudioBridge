// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AudioBridge", targets: ["AudioBridge"]),
        .executable(name: "AudioBridgeProbe", targets: ["AudioBridgeProbe"])
    ],
    targets: [
        .target(name: "AudioBridgeCore"),
        .target(name: "AudioBridgeDiscovery", dependencies: ["AudioBridgeCore"]),
        .target(name: "AudioBridgeRealtime", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "AudioBridgeEngine", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery", "AudioBridgeRealtime"]),
        .executableTarget(name: "AudioBridge", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery", "AudioBridgeEngine"]),
        .executableTarget(name: "AudioBridgeProbe", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery"]),
        .testTarget(name: "AudioBridgeCoreTests", dependencies: ["AudioBridgeCore", "AudioBridgeEngine", "AudioBridgeRealtime"])
    ]
)
