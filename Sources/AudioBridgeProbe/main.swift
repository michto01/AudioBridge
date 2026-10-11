import AudioBridgeDiscovery
import AudioBridgeCore
import AVFAudio
import Foundation

do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let permission: String
    switch AVAudioApplication.shared.recordPermission {
    case .undetermined: permission = "not requested"
    case .granted: permission = "granted"
    case .denied: permission = "denied"
    @unknown default: permission = "unknown"
    }
    let report = ProbeReport(catalog: try CoreAudioCatalog.snapshot(), permissionStatus: permission,
        permissionContext: "CLI process only; does not establish AudioBridge.app permission. No permission requested.")
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Device probe failed: \(error)\n".utf8))
    exit(1)
}
