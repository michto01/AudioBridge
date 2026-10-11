import AppKit
import AudioBridgeAU
import AudioBridgeRealtime
import Foundation

/// Helper-only synchronization. HAL callbacks access only the C shared queues.
final class RenderDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Renderer
    init(_ renderer: Renderer) { current = renderer }
    func replace(_ renderer: Renderer) {
        lock.lock(); let retired = current; current = renderer; lock.unlock()
        withExtendedLifetime(retired) {}
        ABAUTransportReady(renderer.transport, renderer.latencySeconds)
    }
    func setBypass(_ value: Bool) {
        lock.lock(); let transport = current.transport; lock.unlock()
        ABAUTransportSetBypass(transport, value)
    }
    func run() {
        while true {
            lock.lock(); let renderer = current; lock.unlock()
            if ABAUTransportSnapshot(renderer.transport).stopped { return }
            if !renderer.processBlock(bypass: ABAUTransportBypassed(renderer.transport)) { return }
        }
    }
}

@MainActor
final class LiveHost {
    private static var retained: LiveHost?
    private let directory: URL
    private let request: AUWorkerRequest
    private let transport: OpaquePointer
    private let driver: RenderDriver
    private var renderer: Renderer
    private var lastCommand: UUID?
    private var busy = false
    private var timer: Timer?
    init(directory: URL, request: AUWorkerRequest, renderer: Renderer) {
        self.directory = directory; self.request = request; self.renderer = renderer
        transport = renderer.transport; driver = RenderDriver(renderer)
    }
    func start() {
        Self.retained = self
        driver.setBypass(request.bypass == true)
        ABAUTransportReady(transport, renderer.latencySeconds)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let driver = driver
        DispatchQueue.global(qos: .userInteractive).async { driver.run(); exit(0) }
    }
    private func reply(_ response: AULiveResponse) {
        do { try JSONEncoder().encode(response).write(to: directory.appendingPathComponent("response.json"), options: .atomic) }
        catch { ABAUTransportFault(transport, -1) }
        busy = false
    }
    private func poll() {
        Editor.setChainBypassed(ABAUTransportBypassed(transport))
        let close = directory.appendingPathComponent("close-editor")
        if FileManager.default.fileExists(atPath: close.path) {
            try? FileManager.default.removeItem(at: close); Editor.closeLive()
        }
        guard !busy, let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
              data.count <= 96 * 1024 * 1024,
              let command = try? JSONDecoder().decode(AULiveCommand.self, from: data), command.id != lastCommand else { return }
        lastCommand = command.id; busy = true
        if let bypass = command.bypass {
            driver.setBypass(bypass); reply(AULiveResponse(id: command.id)); return
        }
        if let id = command.edit {
            guard let stage = renderer.stages.first(where: { $0.effect.id == id }) else {
                reply(AULiveResponse(id: command.id, error: "Effect is not loaded in the live chain.")); return
            }
            Editor.showLive(effect: stage.effect, wrapper: stage.wrapper, bypassed: ABAUTransportBypassed(transport)) { [weak self] effect, error in
                self?.reply(AULiveResponse(id: command.id, effect: effect, error: error))
            }
            return
        }
        if let chain = command.chain {
            Task {
                do {
                    try chain.validate()
                    let next = Renderer(transport: transport, frames: request.blockFrames)
                    try await next.prepare(request: AUWorkerRequest(chain: chain, sampleRate: request.sampleRate, blockFrames: request.blockFrames))
                    driver.replace(next); renderer = next
                    reply(AULiveResponse(id: command.id))
                } catch {
                    reply(AULiveResponse(id: command.id, error: error.localizedDescription))
                    ABAUTransportFault(transport, -1)
                }
            }
        } else { reply(AULiveResponse(id: command.id, error: "Invalid live AU command.")) }
    }
}
