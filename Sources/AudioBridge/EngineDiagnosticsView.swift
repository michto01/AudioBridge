import AudioBridgeStrings
import AudioBridgeEngine
import AudioBridgeAU
import Foundation
import SwiftUI

struct LiveEngineDiagnostics: View {
    @ObservedObject var telemetry: EngineTelemetry
    var effects: [AUEffect] = []
    var body: some View {
        if let metrics = telemetry.snapshot {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(telemetry.countersResetAt.map { L("Counters since \($0.formatted(date: .omitted, time: .standard))") } ?? L("Counters since routing started"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Reset counters")) { telemetry.resetCounters() }
                    InfoButton(title: L("Reset diagnostic counters"), message: L("Starts a new measurement window for displayed callback, frame, loss, drift-event, AU timing and full-scale sample counts. It does not restart audio, empty queues, reset drift, clear faults or hide a delivery warning. Live values stay live; maxima and observed queue range remain labeled for the entire run. Copy Status includes this measurement window and retains lifetime totals. A new routing attempt starts a new window automatically."))
                }
                EngineDiagnosticsView(metrics: metrics, baseline: telemetry.counterBaseline, effects: effects)
            }
        }
    }
}

/// Keep values in stable rows rather than making the operator parse sentences.
struct EngineDiagnosticsView: View {
    let metrics: EngineSnapshot
    var baseline: EngineSnapshot? = nil
    var effects: [AUEffect] = []
    private var counters: DiagnosticCounterWindow { DiagnosticCounterWindow(snapshot: metrics, baseline: baseline) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InfoGroupBox(L("Audio delivery"), message: L("Callback freshness and priming confirm local audio delivery. Counts cover the current diagnostic measurement window; engine lifetime totals remain in Copy Status. A warning clears after five healthy seconds; queue recentering and rebuffer bookkeeping alone do not trigger it. Full-scale audio is shown separately as a signal level, not a delivery fault.")) {
                VStack(spacing: 8) {
                    ReadoutRow(L("Delivery phase"), metrics.outputFrames == 0
                        ? L("Starting · filling audio queues")
                        : (metrics.primed ? "Delivering" : L("Refilling after delivery loss")))
                    if metrics.recentGlitches {
                        ReadoutRow(L("Warning"), metrics.deliveryWarningReason ?? L("Delivery interrupted")).foregroundStyle(.orange)
                        ReadoutRow(L("Recovery"), L("\(Int(min(5, metrics.glitchCleanSeconds))) / 5 seconds clean"))
                        Divider()
                    }
                    ReadoutRow(L("Input callbacks"), L("\(counters.value(\.inputCallbacks).formatted()) · \(metrics.inputActive ? "fresh" : "not fresh")"))
                    ReadoutRow(L("Output callbacks"), L("\(counters.value(\.outputCallbacks).formatted()) · \(metrics.outputActive ? "fresh" : "not fresh")"))
                    ReadoutRow(L("Captured frames"), L("\(counters.value(\.inputFrames).formatted())"))
                    ReadoutRow(L("Rendered frames"), L("\(counters.value(\.outputFrames).formatted())"))
                    Divider()
                    ReadoutRow(L("Underrun frames"), L("\(counters.value(\.underrunFrames).formatted())"))
                    ReadoutRow(L("Overrun frames"), L("\(counters.value(\.overrunFrames).formatted())"))
                    ReadoutRow(L("Format faults"), L("\(counters.value(\.formatFaults).formatted())"))
                    ReadoutRow(L("Lost / dropped audio · sum"), L("\(number(Double(counters.value(\.underrunFrames)) / metrics.sampleRate * 1000)) / \(number(Double(counters.value(\.overrunFrames)) / metrics.sampleRate * 1000)) ms"))
                }
            }
            InfoGroupBox(L("Queues & clocks"), message: L("Reserve is your FIFO setting. Allocated capacity (minimum 1024 frames) is storage headroom, not another latency setting or a queue filled to that size. A direct bridge uses one queue; an AU route uses separate capture and ready queues, each with this capacity. Pending source counts accepted audio across those queues and the in-flight block without adding the reserve again. Unused capacity adds no audio delay.\n\nThe timestamp-derived clock difference is separate from the occupancy controller's correction command. FIFO occupancy naturally changes between callbacks. A correction value alone is not evidence of lost audio or a physical clock fault. Individual queue snapshots are approximate. A backlog can remain after DSP is switched off; dry forwarding keeps the queued audio rather than silently dropping it to lower the delay.")) {
                VStack(spacing: 8) {
                    ReadoutRow(L("Sample rate"), rate(metrics.sampleRate))
                    ReadoutRow(L("Ready audio queued"), L("\(metrics.bufferedFrames.formatted()) frames"))
                    ReadoutRow(L("Allocated capacity per queue"), L("\(metrics.capacity.formatted()) frames"))
                    ReadoutRow(L("Reserve target"), L("\(metrics.targetFrames.formatted()) frames"))
                    ReadoutRow(L("Primed"), metrics.primed ? "Yes" : "Filling")
                    ReadoutRow(L("Pending source"), L("\(metrics.pendingSourceFrames.formatted()) frames"))
                    if metrics.auBlockFrames > 0 {
                        ReadoutRow(L("Capture / processing / ready"), L("\(metrics.captureQueueFrames.formatted()) / \(metrics.auInFlightFrames.formatted()) / \(metrics.processedQueueFrames.formatted()) frames"))
                    }
                    if let low = metrics.queueLowFrames, let high = metrics.queueHighFrames {
                        ReadoutRow(L("Observed queue range · run"), L("\(low.formatted())–\(high.formatted()) frames"))
                    }
                    Divider()
                    ReadoutRow(L("Measured clock difference"), metrics.clockEstimateValid ? L("\(number(Double(metrics.measuredClockDifferencePPM))) ppm") : "Unavailable")
                    ReadoutRow(L("Correction command"), L("\(number(Double(metrics.driftPPM))) ppm"))
                    ReadoutRow(L("Applied correction"), L("\(number(Double(metrics.appliedDriftPPM))) ppm"))
                    ReadoutRow(L("Saturated callbacks"), L("\(counters.value(\.driftSaturatedCallbacks).formatted())"))
                    ReadoutRow(L("Held / limited callbacks"), L("\(counters.value(\.driftHeldCallbacks).formatted()) / \(counters.value(\.driftLimitedCallbacks).formatted())"))
                    ReadoutRow(L("Refill threshold"), L("\(metrics.refillThresholdFrames.formatted()) frames"))
                    ReadoutRow(L("Rebuffer events"), L("\(counters.value(\.rebufferEvents).formatted())"))
                    ReadoutRow(L("Recentered frames"), L("\(counters.value(\.recenterFrames).formatted())"))
                }
            }
            InfoGroupBox(L("Audio Unit processing"), message: L("Declared plugin signal latency and measured processing wall time describe different things. Wall time includes scheduling and preemption; it is not added to signal delay or equivalent to CPU utilization. Over-budget blocks and late wakes are clues, not proof of an audible glitch. The helper waits for a signaled full block rather than repeatedly sleeping. Wake delay measures notification to worker resume, excluding legitimate idle time. A Mach real-time policy is requested on its dedicated thread; the result below is the setup result, not a guarantee or continuous policy audit. The asynchronous worker uses its own audio workgroup and passes its context to supporting plugins. Interval deadlines describe block throughput; they do not promise device deadlines.\n\nWith 32-frame blocks at 48 kHz, one block is only 0.67 ms. Whole-chain bypass still renders plugins. Switching processing off live retains the helper; Stop and Start with processing off uses the direct bridge without plugin loading. Reset counters before comparisons. Startup filling is expected; subsequent lost frames remain visible even if they are difficult to hear. Per-plugin wall timings are for the current plugin in that slot, including preemption. They are not reset by Reset counters. A plugin's late count compares its own render to the whole block budget; several individually fast plugins can still exceed that budget together. Starvation captures the first short callback, not subsequent refill silence. Queue/stage fields are approximate concurrent samples; an active slot or a previous slow wake is not proof of causality.")) {
                VStack(spacing: 8) {
                    ReadoutRow(L("Processing path"), metrics.auBlockBudgetNanoseconds > 0 ? L("AU helper") : L("Direct bridge"))
                    if let status = metrics.auSchedulingStatus {
                        ReadoutRow(L("Render thread scheduling"), status == 0 ? L("Real-time policy accepted") : (status == -1 ? L("Not configured yet") : L("QoS fallback · Mach status \(status)")))
                        ReadoutRow(L("Audio workgroup"), metrics.auWorkgroupStatus == 0 ? L("Joined") : L("Fallback"))
                        ReadoutRow(L("Workgroup interval failures"), "\(metrics.auWorkgroupIntervalFailures)")
                        ReadoutRow(L("Worker wake method"), L("Signaled queue readiness"))
                    }
                    ReadoutRow(L("Effect DSP"), metrics.effectsProcessingEnabled ? (metrics.chainBypassed ? L("Rendering · dry bypass") : "Enabled") : L("Off · dry forwarding"))
                    ReadoutRow(L("Processed frames"), L("\(counters.value(\.auProcessedFrames).formatted())"))
                    ReadoutRow(L("Effect latency applied"), L("\(number(Double(metrics.auLatencySeconds) * 1000)) ms"))
                    ReadoutRow(L("Block size"), L("\(metrics.auBlockFrames.formatted()) frames"))
                    ReadoutRow(L("Processing budget per block"), milliseconds(metrics.auBlockBudgetNanoseconds))
                    ReadoutRow(L("Timed blocks"), L("\(counters.value(\.auRenderBlocks).formatted())"))
                    ReadoutRow(L("Processing time · last"), milliseconds(metrics.auLastRenderNanoseconds))
                    ReadoutRow(L("Processing time · mean"), counters.value(\.auRenderBlocks) > 0 ? L("\(number(Double(counters.value(\.auRenderNanoseconds)) / Double(counters.value(\.auRenderBlocks)) / 1e6)) ms") : "Unavailable")
                    if counters.value(\.auRenderBlocks) > 0, metrics.auBlockBudgetNanoseconds > 0 {
                        ReadoutRow(L("Mean block allowance used · wall time"), L("\((Double(counters.value(\.auRenderNanoseconds)) / Double(counters.value(\.auRenderBlocks)) / Double(metrics.auBlockBudgetNanoseconds) * 100).formatted(.number.precision(.fractionLength(0))))%"))
                    }
                    ReadoutRow(L("Processing time · maximum run"), milliseconds(metrics.auMaxRenderNanoseconds))
                    ReadoutRow(L("Over-budget blocks"), L("\(counters.value(\.auRenderOverBudgetBlocks).formatted())"))
                    ReadoutRow(L("Late worker wakeups"), L("\(counters.value(\.auWorkerLateWakeups).formatted()) / \(counters.value(\.auWorkerWaits).formatted())"))
                    ReadoutRow(L("Maximum signal-to-wake delay · run"), milliseconds(metrics.auMaxWorkerWakeLatenessNanoseconds))
                    if !metrics.auStages.isEmpty { Text(L("Plugin timings · since slot adoption")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(metrics.auStages.filter { stage in effects.contains { $0.timingIdentity == stage.identity } }, id: \.slot) { stage in
                        let name = effects.first { $0.timingIdentity == stage.identity }?.name ?? "AU"
                        ReadoutRow(name, L("mean \(milliseconds(stage.blocks > 0 ? stage.nanoseconds / stage.blocks : 0)) · max \(milliseconds(stage.maximumNanoseconds)) · \(stage.overBudget) late"))
                    }
                    if let event = metrics.auStarvation, event.sequence > 0 {
                        Divider()
                        ReadoutRow(L("Last AU starvation event"), L("#\(event.sequence) · \(event.lostFrames) frames"))
                        ReadoutRow(L("Capture / ready / processing at loss"), L("\(event.captureFrames) / \(event.readyFrames) / \(event.inFlightFrames) frames"))
                        ReadoutRow(L("Rendering plugin slot at loss"), event.renderingStage < 0 ? L("Idle / transfer") : L("\(event.renderingStage + 1)"))
                        ReadoutRow(L("Previous block / wake delay"), L("\(milliseconds(event.lastRenderNanoseconds)) / \(milliseconds(event.lastWakeNanoseconds))"))
                    }
                }
            }
            InfoGroupBox(L("Signal levels"), message: L("Full-scale sample counts cover the current measurement window and indicate signal level. Digital attenuation cannot repair clipping that happened during capture. Stereo meter counts are shown as Mix L / Mix R; raw input and physical output counts refer to device-side samples.")) {
                VStack(spacing: 8) {
                    ReadoutRow(L("Input full-scale samples · L / R"), counters.pairs(metrics.inputLevels.map(\.clippedSamples), baseline?.inputLevels.map(\.clippedSamples)))
                    ReadoutRow(L("Output full-scale samples · L / R"), counters.pairs(metrics.outputLevels.map(\.clippedSamples), baseline?.outputLevels.map(\.clippedSamples)))
                    ReadoutRow(L("Raw input full-scale samples"), counters.pairs(metrics.rawInputClips, baseline?.rawInputClips))
                    ReadoutRow(L("Physical output full-scale samples"), L("\(counters.value(\.physicalOutputClips).formatted())"))
                    ReadoutRow(L("Physical output peak"), metrics.physicalOutputPeak > 0
                        ? String(format: L("%.0f dB"), 20 * log10(Double(metrics.physicalOutputPeak))) : L("−∞ dB"))
                }
            }
        }
    }
    private func rate(_ value: Double) -> String {
        let kHz = value / 1000
        return L("\(kHz.formatted(.number.precision(.fractionLength(kHz.rounded() == kHz ? 0 : 1)))) kHz")
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    private func milliseconds(_ value: UInt64) -> String { L("\(number(Double(value) / 1e6)) ms") }
}
