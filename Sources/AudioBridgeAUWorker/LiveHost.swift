import AppKit
import AudioBridgeAU
import AudioBridgeRealtime
import Foundation

/// Block-boundary handoff; main retains each retiring renderer until the
/// render thread acknowledges adoption. No render-thread mutex or AU teardown.
final class RenderDriver: @unchecked Sendable {
    private let exchange: OpaquePointer
    private let transport: OpaquePointer
    private let initialLatency: Float
    private var current: Renderer
    init?(_ renderer: Renderer) {
        guard let exchange = ABRendererExchangeCreate() else { return nil }
        self.exchange = exchange; transport = renderer.transport
        initialLatency = renderer.latencySeconds; current = renderer
    }
    deinit { ABRendererExchangeDestroy(exchange) }
    func replace(_ renderer: Renderer) -> Bool {
        ABRendererExchangePublish(exchange, Unmanaged.passUnretained(renderer).toOpaque())
    }
    func adopted(_ renderer: Renderer) -> Bool {
        ABRendererExchangeAdopted(exchange, Unmanaged.passUnretained(renderer).toOpaque())
    }
    func setBypass(_ value: Bool) {
        ABAUTransportSetBypass(transport, value)
    }
    func run() {
        _ = ABAUTransportConfigureRealtimeThread(transport)
        defer { ABAUTransportFinishRealtimeThread(transport) }
        autoreleasepool { current.installRenderContext() }
        // Parent starts HAL only after the actual render thread is scheduled
        // and has finished its policy setup, rather than after Thread.start().
        ABAUTransportReady(transport, initialLatency)
        while true {
            guard ABAUTransportWaitForBlock(transport, current.frames) else { return }
            let cycleStart = ABAUTransportClock()
            var adoptionTicks: UInt64 = 0
            var adopted = false
            if let pointer = ABRendererExchangeTake(exchange) {
                let next = Unmanaged<Renderer>.fromOpaque(pointer).takeUnretainedValue()
                next.wetMix = current.wetMix
                current = next
                autoreleasepool { current.installRenderContext() }
                ABAUTransportSetLatency(transport, current.latencySeconds)
                ABRendererExchangeAcknowledge(exchange, pointer)
                adopted = true; adoptionTicks = ABAUTransportClock() - cycleStart
            }
            let enabled = ABAUTransportEffectsProcessingEnabled(transport)
            let bypass = ABAUTransportBypassed(transport)
            let succeeded: Bool
            if !current.stages.isEmpty && (enabled || current.wetMix > 0) {
                // Bound legacy plugin temporaries. The dry-only path performs
                // no plugin/Objective-C calls and needs no per-block pool.
                succeeded = autoreleasepool {
                    current.processBlock(bypass: bypass, effectsProcessingEnabled: enabled)
                }
            } else {
                succeeded = current.processBlock(bypass: bypass, effectsProcessingEnabled: enabled)
            }
            ABAUTransportRecordCycleTicks(transport, cycleStart, adoptionTicks, adopted)
            if !succeeded { return }
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
    private var pendingRenderer: Renderer?
    private var pendingReplacementID: UUID?
    private var lastCommand: UUID?
    private var busy = false
    private var timer: Timer?
    init(directory: URL, request: AUWorkerRequest, renderer: Renderer) throws {
        self.directory = directory; self.request = request; self.renderer = renderer
        transport = renderer.transport
        guard let driver = RenderDriver(renderer) else { throw AUError("Unable to allocate lock-free render handoff.") }
        self.driver = driver
    }
    func start() {
        Self.retained = self
        driver.setBypass(request.bypass == true)
        ABAUTransportSetEffectsProcessingEnabled(transport, request.effectsProcessingEnabled ?? true)
        ABAUTransportConfigureTiming(transport, renderer.blockBudgetNanoseconds)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        let driver = driver
        // Dedicated ownership avoids occupying a shared GCD worker indefinitely.
        // QoS is the fallback if the render thread's Mach policy request fails.
        // The scheduling result is telemetry, not a deadline guarantee.
        let renderThread = Thread { driver.run(); exit(0) }
        renderThread.name = "AudioBridge AU render"
        renderThread.qualityOfService = .userInteractive
        renderThread.start()
    }
    private func reply(_ response: AULiveResponse) {
        do { try JSONEncoder().encode(response).write(to: directory.appendingPathComponent("response.json"), options: .atomic) }
        catch { ABAUTransportFault(transport, -1) }
        busy = false
    }
    private func poll() {
        if let next = pendingRenderer, let id = pendingReplacementID, driver.adopted(next) {
            // Render has finished with the old chain. Its last strong owner is
            // released here on AppKit's thread, including AU resource teardown.
            renderer = next; pendingRenderer = nil; pendingReplacementID = nil
            reply(AULiveResponse(id: id))
        }
        if pendingRenderer == nil, ABAUTransportTakeLatencyChange(transport) { renderer.refreshLatency() }
        Editor.setChainBypassed(ABAUTransportBypassed(transport))
        Editor.setEffectsProcessingEnabled(ABAUTransportEffectsProcessingEnabled(transport))
        let close = directory.appendingPathComponent("close-editor")
        if FileManager.default.fileExists(atPath: close.path) {
            try? FileManager.default.removeItem(at: close); Editor.closeLive()
            ABAUTransportLatencyChanged(transport)
        }
        let commandURL = directory.appendingPathComponent("command.json")
        guard !busy, let data = try? Data(contentsOf: commandURL),
              data.count <= 96 * 1024 * 1024,
              let command = try? JSONDecoder().decode(AULiveCommand.self, from: data), command.id != lastCommand else { return }
        lastCommand = command.id; busy = true
        // Parent waits for the reply before writing the next command. Consume
        // once instead of decoding potentially large saved states at 10 Hz.
        do { try FileManager.default.removeItem(at: commandURL) }
        catch { reply(AULiveResponse(id: command.id, error: "Unable to consume AU command.")); return }
        if let bypass = command.bypass {
            driver.setBypass(bypass); reply(AULiveResponse(id: command.id)); return
        }
        if let id = command.edit {
            guard let stage = renderer.stages.first(where: { $0.effect.id == id }) else {
                reply(AULiveResponse(id: command.id, error: "Effect is not loaded in the live chain.")); return
            }
            Editor.showLive(effect: stage.effect, wrapper: stage.wrapper, bypassed: ABAUTransportBypassed(transport),
                effectsProcessingEnabled: ABAUTransportEffectsProcessingEnabled(transport)) { [weak self] effect, error in
                if let self { ABAUTransportLatencyChanged(self.transport) }
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
                    pendingRenderer = next; pendingReplacementID = command.id
                    guard driver.replace(next) else {
                        pendingRenderer = nil; pendingReplacementID = nil
                        throw AUError("A chain replacement is already awaiting adoption.")
                    }
                } catch {
                    reply(AULiveResponse(id: command.id, error: error.localizedDescription))
                    ABAUTransportFault(transport, -1)
                }
            }
        } else { reply(AULiveResponse(id: command.id, error: "Invalid live AU command.")) }
    }
}
