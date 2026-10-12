import AudioBridgeAU
import AudioBridgeCore
import AudioBridgeRealtime
import Foundation
import Darwin

/// Process orchestration only. The mapping is released only after HAL callbacks detach.
final class AUHostContext {
    var transport: OpaquePointer?
    let process = Process()
    private let directory: URL
    private var heartbeat: UInt64 = 0
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    var latencySeconds: Float { transport.map { ABAUTransportSnapshot($0).latencySeconds } ?? 0 }
    var processedFrames: UInt64 { transport.map { ABAUTransportSnapshot($0).processedFrames } ?? 0 }
    var metrics: ABAUTransportMetrics? { transport.map { ABAUTransportSnapshot($0) } }

    init(chain: AUChain, plan: Phase2Plan, bypass: Bool = false, effectsProcessingEnabled: Bool = true, cancelled: () -> Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioBridge-AU-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try chain.validate()
            let name = "/abau" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22)
            guard let mapping = ABAUTransportCreate(String(name), plan.capacity) else {
                throw AUError("Cannot allocate AU shared memory: \(String(cString: ABAUTransportLastError())).")
            }
            transport = mapping
            let request = AUWorkerRequest(chain: chain, sampleRate: plan.sampleRate, blockFrames: plan.auBlockFrames,
                bypass: bypass, effectsProcessingEnabled: effectsProcessingEnabled)
            let configuration = directory.appendingPathComponent("request.json")
            try JSONEncoder().encode(request).write(to: configuration, options: .atomic)
            process.executableURL = Self.workerURL
            process.arguments = ["render", String(name), configuration.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while true {
                if cancelled() { throw AUError("AU preparation cancelled.") }
                let facts = ABAUTransportSnapshot(mapping)
                if facts.fault != 0 { throw AUError("AU chain could not prepare (OSStatus \(facts.fault)). Check selected plugins and saved settings.") }
                if facts.ready { ABAUTransportUnlink(mapping); break }
                if !process.isRunning { throw BridgeFailure("AU helper exited while preparing. Stop retries and inspect the plugin if this persists.", kind: .recoverable) }
                if ProcessInfo.processInfo.systemUptime > deadline { throw BridgeFailure("AU preparation timed out. Routing was not started.", kind: .recoverable) }
                usleep(10_000)
            }
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
        } catch { close(); throw error }
    }
    static var workerURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioBridgeAUWorker")
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("AudioBridgeAUWorker")
    }
    private var pending: AULiveCommand?
    func bypass(_ value: Bool) throws {
        guard let transport else { throw AUError("AU shared memory unavailable.") }
        ABAUTransportSetBypass(transport, value)
    }
    func setEffectsProcessingEnabled(_ value: Bool) throws {
        guard let transport else { throw AUError("AU shared memory unavailable.") }
        ABAUTransportSetEffectsProcessingEnabled(transport, value)
    }
    func closeEditor() throws {
        try Data().write(to: directory.appendingPathComponent("close-editor"), options: .atomic)
    }
    private var pendingSince: Double = 0
    private(set) var response: AULiveResponse?
    func command(_ command: AULiveCommand) throws {
        guard pending == nil, process.isRunning else { throw AUError("AU helper is busy or unavailable.") }
        try JSONEncoder().encode(command).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        pending = command; pendingSince = ProcessInfo.processInfo.systemUptime; response = nil
    }
    private func pollResponse() {
        guard let pending else { return }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("response.json")), data.count <= 16 * 1024 * 1024,
           let reply = try? JSONDecoder().decode(AULiveResponse.self, from: data), reply.id == pending.id {
            response = reply; self.pending = nil
        }
    }
    func fault() -> BridgeFailure? {
        pollResponse()
        if let pending, pending.edit == nil, ProcessInfo.processInfo.systemUptime - pendingSince > 30 {
            return BridgeFailure("Live AU update timed out; routing stopped without bypassing the requested chain.", kind: .actionRequired)
        }
        guard let transport else { return BridgeFailure("AU shared memory is unavailable.", kind: .actionRequired) }
        let facts = ABAUTransportSnapshot(transport)
        if facts.fault != 0 { return BridgeFailure("AU render failed (OSStatus \(facts.fault)); routing stopped without bypassing the chain.", kind: .actionRequired) }
        if !process.isRunning { return BridgeFailure("AU helper exited; routing stopped without bypassing the chain.", kind: .recoverable) }
        if facts.heartbeat != heartbeat { heartbeat = facts.heartbeat; lastHeartbeat = ProcessInfo.processInfo.systemUptime }
        if ProcessInfo.processInfo.systemUptime - lastHeartbeat > 2 { return BridgeFailure("AU helper stopped responding; routing stopped without bypassing the chain.", kind: .recoverable) }
        return nil
    }
    func close(releaseMapping: Bool = true) {
        if let transport { ABAUTransportShutdown(transport) }
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        if let transport {
            ABAUTransportUnlink(transport)
            if releaseMapping { ABAUTransportClose(transport) }
            // Failed HAL detach deliberately retains the mapping, even after this Swift owner ends.
            self.transport = nil
        }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
}
