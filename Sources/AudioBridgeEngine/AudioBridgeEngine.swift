import AudioBridgeCore
import AudioBridgeAU
import AudioBridgeDiscovery
import AudioBridgeRealtime
import Foundation

public struct EngineSnapshot: Sendable {
    public let inputCallbacks: UInt64
    public let outputCallbacks: UInt64
    public let inputFrames: UInt64
    public let outputFrames: UInt64
    public let underrunFrames: UInt64
    public let overrunFrames: UInt64
    public let formatFaults: UInt64
    public let bufferedFrames: UInt32
    public let primed: Bool
    public let sampleRate: Double
    public let fault: String?
    public let inputLevels: [MeterLevel]
    public let outputLevels: [MeterLevel]
    public let inputActive: Bool
    public let outputActive: Bool
    public let capacity: UInt32
    public let targetFrames: UInt32
    public let rawInputClips: [UInt64]
    public let auLatencySeconds: Float
    public let auProcessedFrames: UInt64
    public let auResponse: AULiveResponse?
    public let driftPPM: Float
    public let recenterFrames: UInt64
    public let rebufferEvents: UInt64
    public let physicalOutputPeak: Float
    public let physicalOutputClips: UInt64
    public let captureQueueFrames: UInt32
    public let processedQueueFrames: UInt32
    public let auInFlightFrames: UInt32
    public let auBlockFrames: UInt32
    public let resamplerLookaheadFrames: UInt32
    public let queueLowFrames: UInt64?
    public let queueHighFrames: UInt64?
    public let auRenderBlocks: UInt64
    public let auRenderNanoseconds: UInt64
    public let auLastRenderNanoseconds: UInt64
    public let auMaxRenderNanoseconds: UInt64
    public let delayInputDevice: DeviceFacts
    public let delayOutputDevice: DeviceFacts
    public let delaySelection: RouteSelection
    public let chainBypassed: Bool
    public let recentGlitches: Bool
    public let glitchCleanSeconds: Double
}

public struct MeterLevel: Sendable {
    public let amplitude: Float
    public let clippedSamples: UInt64
    public init(amplitude: Float, clippedSamples: UInt64) {
        self.amplitude = amplitude.isFinite ? max(0, amplitude) : 0
        self.clippedSamples = clippedSamples
    }
    public var decibels: Double { amplitude > 0 ? 20 * log10(Double(amplitude)) : -.infinity }
}

/// All HAL lifecycle calls and C context ownership are confined to one non-realtime queue.
/// No Swift closure or object is called from the device IO callbacks.
public final class AudioBridgeEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cz.bytelab.audiobridge.engine", qos: .userInitiated)
    private var context: OpaquePointer?
    private var plan: Phase2Plan?
    private var watchdog: DispatchSourceTimer?
    private var startedAt = Date()
    private var previousInputCallbacks: UInt64 = 0
    private var previousOutputCallbacks: UInt64 = 0
    private var lastDeviceCheck = Date.distantPast
    private var lastInputActivity: Date?
    private var lastOutputActivity: Date?
    private var auHost: AUHostContext?
    private let preparationLock = NSLock()
    private var preparationCancelled = false
    private var queueLowFrames: UInt64?
    private var queueHighFrames: UInt64?
    private var activeSelection = RouteSelection()
    private var delayInputDevice: DeviceFacts?
    private var delayOutputDevice: DeviceFacts?
    private var recentGlitches = RecentGlitches()

    public init() {}
    public func start(selection: RouteSelection, profile: BufferProfile = .balanced,
                      bufferFrames: UInt32? = nil, inputTrim: Double = 0, outputGain: Double = 0, effects: AUChain = AUChain(), chainBypass: Bool = false,
                      updated: @escaping @Sendable (EngineSnapshot) -> Void,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        preparationLock.lock(); preparationCancelled = false; preparationLock.unlock()
        queue.async { [self] in
            do {
                guard context == nil else { throw Phase2Plan.PlanError("The previous engine has not fully stopped. Stop it before starting again.") }
                // Fresh UID resolution and format validation; never use UI runtime IDs or defaults.
                let fresh = try CoreAudioCatalog.snapshot()
                let next = try Phase2Plan(selection: selection, devices: fresh.devices, profile: profile, bufferFrames: bufferFrames)
                guard let created = ABEngineCreate(next.input.device.runtimeID, next.output.device.runtimeID,
                    next.capacity, next.prefill) else {
                    throw Phase2Plan.PlanError("Unable to allocate callback buffers or lock-free counters.")
                }
                context = created; plan = next; activeSelection = selection
                delayInputDevice = next.input.device; delayOutputDevice = next.output.device
                let routing = try Self.makeRouting(next, selection: selection)
                guard ABEngineAttachRouting(created, routing) else { ABRoutingDestroy(routing); throw AUError("Unable to attach physical channel routing.") }
                guard ABEngineConfigureDrift(created, next.sampleRate, next.input.device.bufferFrames ?? 512) else { throw AUError("Invalid drift configuration.") }
                do {
                    guard next.prefill >= 16 else { throw AUError("Bridge startup fill must be at least 16 frames.") }
                    auHost = try AUHostContext(chain: effects, plan: next, bypass: chainBypass, cancelled: { [self] in
                        self.preparationLock.lock(); defer { self.preparationLock.unlock() }; return self.preparationCancelled
                    })
                    guard ABEngineAttachAU(created, auHost?.transport) else { throw AUError("Unable to attach AU shared buffers.") }
                }
                ABEngineInitialGains(created, GainSettings.amplitude(decibels: inputTrim), GainSettings.amplitude(decibels: outputGain), UInt32(min(65536, max(1, next.sampleRate * 0.02))))
                let status = ABEngineStart(created)
                guard status == 0 else {
                    let cleanup = stopOnQueue()
                    throw Phase2Plan.PlanError("Unable to start the selected devices (OSStatus \(status)). \(cleanup ?? "")")
                }
                startedAt = Date(); previousInputCallbacks = 0; previousOutputCallbacks = 0
                queueLowFrames = nil; queueHighFrames = nil
                recentGlitches = RecentGlitches()
                lastInputActivity = nil; lastOutputActivity = nil; lastDeviceCheck = .distantPast
                let timer = DispatchSource.makeTimerSource(queue: queue)
                watchdog = timer
                timer.schedule(deadline: .now(), repeating: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.poll(updated: updated) }
                timer.resume()
                completion(.success(()))
            } catch {
                let cleanup = stopOnQueue()
                completion(.failure(AUError(error.localizedDescription + (cleanup.map { " \($0)" } ?? ""))))
            }
        }
    }
    public func stop(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        preparationLock.lock(); preparationCancelled = true; preparationLock.unlock()
        queue.async { [self] in
            if let error = stopOnQueue() { completion(.failure(Phase2Plan.PlanError(error))) }
            else { completion(.success(())) }
        }
    }
    public func setGains(inputTrim: Double, outputGain: Double) {
        queue.async { [self] in
            guard let context else { return }
            ABEngineSetGains(context, GainSettings.amplitude(decibels: inputTrim), GainSettings.amplitude(decibels: outputGain))
        }
    }
    private static func makeRouting(_ plan: Phase2Plan, selection: RouteSelection) throws -> OpaquePointer {
        let ig = plan.input.inputGains(selection), og = plan.output.outputGains(selection)
        // C copies topology/coefficients synchronously. Swift arrays never escape into callbacks.
        let routing = plan.input.addresses.withUnsafeBufferPointer { ia in
            plan.input.bufferChannels.withUnsafeBufferPointer { ib in
                ig.withUnsafeBufferPointer { gains in
                    plan.output.addresses.withUnsafeBufferPointer { oa in
                        plan.output.bufferChannels.withUnsafeBufferPointer { ob in
                            og.withUnsafeBufferPointer { outputs in
                                ABRoutingCreate(ia.baseAddress, UInt32(ia.count), ib.baseAddress, UInt32(ib.count), gains.baseAddress,
                                    oa.baseAddress, UInt32(oa.count), ob.baseAddress, UInt32(ob.count), outputs.baseAddress)
                            }
                        }
                    }
                }
            }
        }
        guard let routing else { throw AUError("Unable to allocate validated physical channel routing.") }
        return routing
    }
    public func setRouting(_ selection: RouteSelection, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard let context, let plan else { completion(.success(())); return }
                guard selection.patchesValid, selection.input.uid == plan.input.device.uid,
                      selection.output.uid == plan.output.device.uid,
                      selection.inputMix.allSatisfy({ plan.input.physicalChannels.contains($0.channel) }),
                      selection.outputMap.allSatisfy({ plan.output.physicalChannels.contains($0.channel) }) else {
                    throw AUError("Live routing does not match the prepared device channels.")
                }
                let input = plan.input.inputGains(selection), output = plan.output.outputGains(selection)
                let applied = input.withUnsafeBufferPointer { i in output.withUnsafeBufferPointer { o in
                    ABEngineSetRouting(context, i.baseAddress, UInt32(i.count / 2), o.baseAddress, UInt32(o.count / 2))
                } }
                guard applied else { throw AUError("Live routing publication failed.") }
                activeSelection = selection
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
    public func auCommand(_ command: AULiveCommand, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard let auHost else { throw AUError("AU helper is unavailable. Start routing first.") }
                try auHost.command(command); completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
    public func auControl(bypass: Bool? = nil, closeEditor: Bool = false,
                          completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard let auHost else { throw AUError("AU helper unavailable.") }
                if let bypass { try auHost.bypass(bypass) }
                if closeEditor { try auHost.closeEditor() }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
    private func poll(updated: @escaping @Sendable (EngineSnapshot) -> Void) {
        guard let context, let plan else { return }
        let metrics = ABEngineMetrics(context)
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        if metrics.inputCallbacks > previousInputCallbacks { lastInputActivity = now }
        if metrics.outputCallbacks > previousOutputCallbacks { lastOutputActivity = now }
        // A device may deliver less often than UI polls; do not flash Inactive between healthy callbacks.
        let grace = max(0.25, Double(max(plan.input.device.bufferFrames ?? 512, plan.output.device.bufferFrames ?? 512)) / plan.sampleRate * 3)
        let inputActive = lastInputActivity.map { now.timeIntervalSince($0) <= grace } ?? false
        let outputActive = lastOutputActivity.map { now.timeIntervalSince($0) <= grace } ?? false
        previousInputCallbacks = metrics.inputCallbacks; previousOutputCallbacks = metrics.outputCallbacks
        var fault: String?
        if let auFault = auHost?.fault() { fault = auFault }
        if fault == nil, metrics.formatFaults > 0 { fault = "Audio buffer layout changed or became invalid. Refresh devices and start again." }
        else if fault == nil, elapsed > 5 && ((lastInputActivity.map { now.timeIntervalSince($0) > 2 } ?? true)
            || (lastOutputActivity.map { now.timeIntervalSince($0) > 2 } ?? true)
            || (!metrics.primed && metrics.rebufferEvents == 0)) {
            let missing = [
                lastInputActivity.map { now.timeIntervalSince($0) <= 2 } == true ? nil : "input callbacks",
                lastOutputActivity.map { now.timeIntervalSince($0) <= 2 } == true ? nil : "output callbacks",
                metrics.primed ? nil : "processed startup buffer"
            ].compactMap { $0 }.joined(separator: ", ")
            fault = "No confirmed \(missing). Input callbacks: \(metrics.inputCallbacks), output callbacks: \(metrics.outputCallbacks), captured: \(metrics.inputFrames), AU processed: \(auHost?.processedFrames ?? 0), queued: \(metrics.bufferedFrames)/\(plan.prefill + ABResamplerLookahead()) frames. Check selected devices and microphone permission."
        }
        // Recheck UID, liveness and stream formats on the lifecycle queue, never in a callback.
        // A stale/failed probe makes this experimental path stop safely; recovery is a later phase.
        if fault == nil, Date().timeIntervalSince(lastDeviceCheck) >= 0.5 {
          lastDeviceCheck = Date()
          do {
            let fresh = try CoreAudioCatalog.snapshot()
            let input = fresh.devices.first { $0.uid == plan.input.device.uid }
            let output = fresh.devices.first { $0.uid == plan.output.device.uid }
            if input?.alive != true || output?.alive != true
                || input?.runtimeID != plan.input.device.runtimeID || output?.runtimeID != plan.output.device.runtimeID
                || input?.input.matchesRoutingTopology(plan.input.device.input) != true
                || output?.output.matchesRoutingTopology(plan.output.device.output) != true
                || input?.bufferFrames != plan.input.device.bufferFrames || output?.bufferFrames != plan.output.device.bufferFrames
                || input?.nominalSampleRate != plan.sampleRate || output?.nominalSampleRate != plan.sampleRate {
                fault = "A selected device or its format changed. Routing stopped without choosing another device."
            } else {
                delayInputDevice = input; delayOutputDevice = output
            }
          } catch { fault = "Device recheck failed: \(error.localizedDescription)" }
        }
        let auMetrics = auHost?.metrics
        let auLatency = auMetrics?.latencySeconds ?? 0
        let auFrames = auMetrics?.processedFrames ?? 0
        // Independently sampled queues: occupancy estimate, not a tagged-sample
        // transit measurement. Include a block removed from capture but in flight.
        let queued = UInt64(auMetrics?.inputFrames ?? 0) + UInt64(auMetrics?.outputFrames ?? 0) + UInt64(auMetrics?.inFlightFrames ?? 0)
        if metrics.primed {
            queueLowFrames = min(queueLowFrames ?? queued, queued)
            queueHighFrames = max(queueHighFrames ?? queued, queued)
        }
        let auResponse = auHost?.response
        recentGlitches.update(now: ProcessInfo.processInfo.systemUptime,
            healthy: fault == nil && metrics.primed && inputActive && outputActive && metrics.outputFrames > 0,
            counters: DeliveryCounters(underruns: metrics.underrunFrames, overruns: metrics.overrunFrames,
                formatFaults: metrics.formatFaults, rebuffers: metrics.rebufferEvents, recentered: metrics.recenterFrames))
        if let reason = fault, let cleanup = stopOnQueue() { fault = "\(reason) \(cleanup)" }
        let snapshot = EngineSnapshot(inputCallbacks: metrics.inputCallbacks, outputCallbacks: metrics.outputCallbacks,
            inputFrames: metrics.inputFrames, outputFrames: metrics.outputFrames,
            underrunFrames: metrics.underrunFrames, overrunFrames: metrics.overrunFrames,
            formatFaults: metrics.formatFaults, bufferedFrames: metrics.bufferedFrames,
            primed: metrics.primed, sampleRate: plan.sampleRate, fault: fault,
            inputLevels: [MeterLevel(amplitude: metrics.inputLevels.peak1, clippedSamples: metrics.inputLevels.clips1),
                          MeterLevel(amplitude: metrics.inputLevels.peak2, clippedSamples: metrics.inputLevels.clips2)],
            outputLevels: [MeterLevel(amplitude: metrics.outputLevels.peak1, clippedSamples: metrics.outputLevels.clips1),
                           MeterLevel(amplitude: metrics.outputLevels.peak2, clippedSamples: metrics.outputLevels.clips2)],
            inputActive: inputActive, outputActive: outputActive && metrics.primed,
            capacity: plan.capacity, targetFrames: plan.prefill,
            rawInputClips: [metrics.rawInputClips1, metrics.rawInputClips2],
            auLatencySeconds: auLatency, auProcessedFrames: auFrames, auResponse: auResponse,
            driftPPM: metrics.driftPPM, recenterFrames: metrics.recenterFrames, rebufferEvents: metrics.rebufferEvents,
            physicalOutputPeak: metrics.physicalOutputPeak, physicalOutputClips: metrics.physicalOutputClips,
            captureQueueFrames: auMetrics?.inputFrames ?? 0, processedQueueFrames: auMetrics?.outputFrames ?? 0,
            auInFlightFrames: auMetrics?.inFlightFrames ?? 0, auBlockFrames: plan.auBlockFrames,
            resamplerLookaheadFrames: ABResamplerLookahead(), queueLowFrames: queueLowFrames, queueHighFrames: queueHighFrames,
            auRenderBlocks: auMetrics?.renderBlocks ?? 0, auRenderNanoseconds: auMetrics?.renderNanoseconds ?? 0,
            auLastRenderNanoseconds: auMetrics?.lastRenderNanoseconds ?? 0, auMaxRenderNanoseconds: auMetrics?.maxRenderNanoseconds ?? 0,
            delayInputDevice: delayInputDevice ?? plan.input.device, delayOutputDevice: delayOutputDevice ?? plan.output.device, delaySelection: activeSelection,
            chainBypassed: auMetrics?.bypassed ?? false,
            recentGlitches: recentGlitches.active, glitchCleanSeconds: recentGlitches.cleanSeconds)
        updated(snapshot)
    }
    private func stopOnQueue() -> String? {
        watchdog?.setEventHandler {}; watchdog?.cancel(); watchdog = nil
        guard let context else { return nil }
        let status = ABEngineStop(context)
        if ABEngineDestroy(context) { self.context = nil; plan = nil }
        else {
            auHost?.close(releaseMapping: false); auHost = nil
            return "HAL teardown could not be confirmed. Callback memory is retained; restart the app before another route."
        }
        auHost?.close(); auHost = nil
        return status == 0 ? nil : "Device stop reported OSStatus \(status); callbacks were detached."
    }
    deinit {
        // No timer owns this object; queued methods retain it until their lifecycle work finishes.
        watchdog?.setEventHandler {}; watchdog?.cancel()
        if let context {
            let detached = ABEngineDestroy(context)
            auHost?.close(releaseMapping: detached)
        }
    }
}
