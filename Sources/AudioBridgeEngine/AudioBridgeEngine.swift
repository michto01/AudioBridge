import AudioBridgeCore
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

    public init() {}
    public func start(selection: RouteSelection, profile: BufferProfile = .balanced,
                      updated: @escaping @Sendable (EngineSnapshot) -> Void,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard context == nil else { throw Phase2Plan.PlanError("The previous engine has not fully stopped. Stop it before starting again.") }
                // Fresh UID resolution and format validation; never use UI runtime IDs or defaults.
                let fresh = try CoreAudioCatalog.snapshot()
                let next = try Phase2Plan(selection: selection, devices: fresh.devices, profile: profile)
                guard let created = ABEngineCreate(next.input.device.runtimeID, next.output.device.runtimeID,
                    next.input.layout, next.output.layout, next.capacity, next.prefill) else {
                    throw Phase2Plan.PlanError("Unable to allocate callback buffers or lock-free counters.")
                }
                context = created; plan = next
                let status = ABEngineStart(created)
                guard status == 0 else {
                    let cleanup = stopOnQueue()
                    throw Phase2Plan.PlanError("Unable to start the selected devices (OSStatus \(status)). \(cleanup ?? "")")
                }
                startedAt = Date(); previousInputCallbacks = 0; previousOutputCallbacks = 0
                lastInputActivity = nil; lastOutputActivity = nil; lastDeviceCheck = .distantPast
                let timer = DispatchSource.makeTimerSource(queue: queue)
                watchdog = timer
                timer.schedule(deadline: .now(), repeating: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.poll(updated: updated) }
                timer.resume()
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
    public func stop(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            if let error = stopOnQueue() { completion(.failure(Phase2Plan.PlanError(error))) }
            else { completion(.success(())) }
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
        if metrics.formatFaults > 0 { fault = "Audio buffer layout changed or became invalid. Refresh devices and start again." }
        else if elapsed > 5 && ((lastInputActivity.map { now.timeIntervalSince($0) > 2 } ?? true)
            || (lastOutputActivity.map { now.timeIntervalSince($0) > 2 } ?? true) || !metrics.primed) {
            fault = "Selected devices are not delivering confirmed callbacks and buffers. Check devices and microphone permission."
        }
        // Recheck UID, liveness and stream formats on the lifecycle queue, never in a callback.
        // A stale/failed probe makes this experimental path stop safely; recovery is a later phase.
        if Date().timeIntervalSince(lastDeviceCheck) >= 0.5 {
          lastDeviceCheck = Date()
          do {
            let fresh = try CoreAudioCatalog.snapshot()
            let input = fresh.devices.first { $0.uid == plan.input.device.uid }
            let output = fresh.devices.first { $0.uid == plan.output.device.uid }
            if input?.alive != true || output?.alive != true
                || input?.runtimeID != plan.input.device.runtimeID || output?.runtimeID != plan.output.device.runtimeID
                || input?.input != plan.input.device.input || output?.output != plan.output.device.output
                || input?.nominalSampleRate != plan.sampleRate || output?.nominalSampleRate != plan.sampleRate {
                fault = "A selected device or its format changed. Routing stopped without choosing another device."
            }
          } catch { fault = "Device recheck failed: \(error.localizedDescription)" }
        }
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
            capacity: plan.capacity, targetFrames: plan.prefill)
        updated(snapshot)
    }
    private func stopOnQueue() -> String? {
        watchdog?.setEventHandler {}; watchdog?.cancel(); watchdog = nil
        guard let context else { return nil }
        let status = ABEngineStop(context)
        if ABEngineDestroy(context) { self.context = nil; plan = nil }
        else { return "HAL teardown could not be confirmed. Callback memory is retained; restart the app before another route." }
        return status == 0 ? nil : "Device stop reported OSStatus \(status); callbacks were detached."
    }
    deinit {
        // No timer owns this object; queued methods retain it until their lifecycle work finishes.
        watchdog?.setEventHandler {}; watchdog?.cancel()
        if let context { _ = ABEngineDestroy(context) } // Failed teardown deliberately retains C memory.
    }
}
