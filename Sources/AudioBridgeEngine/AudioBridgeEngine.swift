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
    private var stalledPolls = 0

    public init() {}
    public func start(selection: RouteSelection,
                      updated: @escaping @Sendable (EngineSnapshot) -> Void,
                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard context == nil else { throw Phase2Plan.PlanError("The previous engine has not fully stopped. Stop it before starting again.") }
                // Fresh UID resolution and format validation; never use UI runtime IDs or defaults.
                let fresh = try CoreAudioCatalog.snapshot()
                let next = try Phase2Plan(selection: selection, devices: fresh.devices)
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
                startedAt = Date(); previousInputCallbacks = 0; previousOutputCallbacks = 0; stalledPolls = 0
                let timer = DispatchSource.makeTimerSource(queue: queue)
                watchdog = timer
                timer.schedule(deadline: .now(), repeating: .milliseconds(500))
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
        let elapsed = Date().timeIntervalSince(startedAt)
        if metrics.inputCallbacks == previousInputCallbacks || metrics.outputCallbacks == previousOutputCallbacks {
            stalledPolls += 1
        } else { stalledPolls = 0 }
        previousInputCallbacks = metrics.inputCallbacks; previousOutputCallbacks = metrics.outputCallbacks
        var fault: String?
        if metrics.formatFaults > 0 { fault = "Audio buffer layout changed or became invalid. Refresh devices and start again." }
        else if elapsed > 5 && (stalledPolls >= 4 || !metrics.primed) {
            fault = "Selected devices are not delivering confirmed callbacks and buffers. Check devices and microphone permission."
        }
        // Recheck UID, liveness and stream formats on the lifecycle queue, never in a callback.
        // A stale/failed probe makes this experimental path stop safely; recovery is a later phase.
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
        if fault != nil, let cleanup = stopOnQueue() { fault = "\(fault!) \(cleanup)" }
        let snapshot = EngineSnapshot(inputCallbacks: metrics.inputCallbacks, outputCallbacks: metrics.outputCallbacks,
            inputFrames: metrics.inputFrames, outputFrames: metrics.outputFrames,
            underrunFrames: metrics.underrunFrames, overrunFrames: metrics.overrunFrames,
            formatFaults: metrics.formatFaults, bufferedFrames: metrics.bufferedFrames,
            primed: metrics.primed, sampleRate: plan.sampleRate, fault: fault)
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
