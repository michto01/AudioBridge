// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AudioBridge", targets: ["AudioBridge"]),
        .executable(name: "AudioBridgeAUWorker", targets: ["AudioBridgeAUWorker"]),
        .executable(name: "AudioBridgeProbe", targets: ["AudioBridgeProbe"])
    ],
    targets: [
        .target(name: "AudioBridgeCore"),
        .target(name: "AudioBridgeDiscovery", dependencies: ["AudioBridgeCore"]),
        .target(name: "AudioBridgeRealtime", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "AudioBridgeAU", linkerSettings: [.linkedFramework("AudioToolbox")]),
        .target(name: "AudioBridgeEngine", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery", "AudioBridgeRealtime", "AudioBridgeAU"]),
        .executableTarget(name: "AudioBridgeAUWorker", dependencies: ["AudioBridgeAU", "AudioBridgeRealtime"]),
        .executableTarget(name: "AudioBridge", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery", "AudioBridgeEngine", "AudioBridgeAU"]),
        .executableTarget(name: "AudioBridgeProbe", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery"]),
        .testTarget(name: "AudioBridgeCoreTests", dependencies: ["AudioBridgeCore", "AudioBridgeEngine", "AudioBridgeRealtime", "AudioBridgeAU"])
    ]
)
