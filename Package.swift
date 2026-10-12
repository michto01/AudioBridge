// swift-tools-version: 5.9
import PackageDescription
import Foundation

let appInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Info.plist").path

let package = Package(
    name: "AudioBridge",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AudioBridge", targets: ["AudioBridge"]),
        .executable(name: "AudioBridgeAUWorker", targets: ["AudioBridgeAUWorker"]),
        .executable(name: "AudioBridgeProbe", targets: ["AudioBridgeProbe"])
    ],
    targets: [
        .target(name: "AudioBridgeCore"),
        .target(name: "AudioBridgeStrings", resources: [.process("Resources")]),
        .target(name: "AudioBridgeDiscovery", dependencies: ["AudioBridgeCore"]),
        .target(name: "AudioBridgeRealtime", linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
        .target(name: "AudioBridgeAU", linkerSettings: [.linkedFramework("AudioToolbox")]),
        .target(name: "AudioBridgeEngine", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery", "AudioBridgeRealtime", "AudioBridgeAU"]),
        .target(name: "AudioBridgeAUViews", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AudioToolbox")]),
        .executableTarget(name: "AudioBridgeAUWorker", dependencies: ["AudioBridgeAU", "AudioBridgeRealtime", "AudioBridgeAUViews", "AudioBridgeStrings"]),
        .executableTarget(name: "AudioBridge", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery", "AudioBridgeEngine", "AudioBridgeAU", "AudioBridgeStrings"],
            linkerSettings: [.linkedFramework("ServiceManagement"), .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", appInfoPlist])]),
        .executableTarget(name: "AudioBridgeProbe", dependencies: ["AudioBridgeCore", "AudioBridgeDiscovery"]),
        .testTarget(name: "AudioBridgeCoreTests", dependencies: ["AudioBridgeCore", "AudioBridgeEngine", "AudioBridgeRealtime", "AudioBridgeAU"])
    ]
)
