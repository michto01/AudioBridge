import AudioBridgeEngine
import Foundation
import SwiftUI

struct LiveEngineDiagnostics: View {
    @ObservedObject var telemetry: EngineTelemetry
    var body: some View {
        if let metrics = telemetry.snapshot {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(telemetry.countersResetAt.map { "Counters since \($0.formatted(date: .omitted, time: .standard))" } ?? "Counters since routing started")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset counters") { telemetry.resetCounters() }
                    InfoButton(title: "Reset diagnostic counters", message: "Starts a new measurement window for displayed callback, frame, loss, drift-event, AU timing and full-scale sample counts. It does not restart audio, empty queues, reset drift, clear faults or hide a delivery warning. Live values stay live; maxima and observed queue range remain labeled for the entire run. Copy Status includes this measurement window and retains lifetime totals. A new routing attempt starts a new window automatically.")
                }
                EngineDiagnosticsView(metrics: metrics, baseline: telemetry.counterBaseline)
            }
        }
    }
}

/// Keep values in stable rows rather than making the operator parse sentences.
struct EngineDiagnosticsView: View {
    let metrics: EngineSnapshot
    var baseline: EngineSnapshot? = nil
    private var counters: DiagnosticCounterWindow { DiagnosticCounterWindow(snapshot: metrics, baseline: baseline) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InfoGroupBox("Audio delivery", message: "Callback freshness and priming confirm local audio delivery. Counts cover the current diagnostic measurement window; engine lifetime totals remain in Copy Status. A warning clears after five healthy seconds; queue recentering and rebuffer bookkeeping alone do not trigger it. Full-scale audio is shown separately as a signal level, not a delivery fault.") {
                VStack(spacing: 8) {
                    ReadoutRow("Delivery phase", metrics.outputFrames == 0
                        ? "Starting · filling audio queues"
                        : (metrics.primed ? "Delivering" : "Refilling after delivery loss"))
                    if metrics.recentGlitches {
                        ReadoutRow("Warning", metrics.deliveryWarningReason ?? "Delivery interrupted").foregroundStyle(.orange)
                        ReadoutRow("Recovery", "\(Int(min(5, metrics.glitchCleanSeconds))) / 5 seconds clean")
                        Divider()
                    }
                    ReadoutRow("Input callbacks", "\(counters.value(\.inputCallbacks).formatted()) · \(metrics.inputActive ? "fresh" : "not fresh")")
                    ReadoutRow("Output callbacks", "\(counters.value(\.outputCallbacks).formatted()) · \(metrics.outputActive ? "fresh" : "not fresh")")
                    ReadoutRow("Captured frames", "\(counters.value(\.inputFrames).formatted())")
                    ReadoutRow("Rendered frames", "\(counters.value(\.outputFrames).formatted())")
                    Divider()
                    ReadoutRow("Underrun frames", "\(counters.value(\.underrunFrames).formatted())")
                    ReadoutRow("Overrun frames", "\(counters.value(\.overrunFrames).formatted())")
                    ReadoutRow("Format faults", "\(counters.value(\.formatFaults).formatted())")
                    ReadoutRow("Lost / dropped audio · sum", "\(number(Double(counters.value(\.underrunFrames)) / metrics.sampleRate * 1000)) / \(number(Double(counters.value(\.overrunFrames)) / metrics.sampleRate * 1000)) ms")
                }
            }
            InfoGroupBox("Queues & clocks", message: "Reserve is your FIFO setting. Allocated capacity (minimum 1024 frames) is storage headroom, not another latency setting or a queue filled to that size. A direct bridge uses one queue; an AU route uses separate capture and ready queues, each with this capacity. Pending source counts accepted audio across those queues and the in-flight block without adding the reserve again. Unused capacity adds no audio delay.\n\nThe timestamp-derived clock difference is separate from the occupancy controller's correction command. FIFO occupancy naturally changes between callbacks. A correction value alone is not evidence of lost audio or a physical clock fault. Individual queue snapshots are approximate. A backlog can remain after DSP is switched off; dry forwarding keeps the queued audio rather than silently dropping it to lower the delay.") {
                VStack(spacing: 8) {
                    ReadoutRow("Sample rate", rate(metrics.sampleRate))
                    ReadoutRow("Ready audio queued", "\(metrics.bufferedFrames.formatted()) frames")
                    ReadoutRow("Allocated capacity per queue", "\(metrics.capacity.formatted()) frames")
                    ReadoutRow("Reserve target", "\(metrics.targetFrames.formatted()) frames")
                    ReadoutRow("Primed", metrics.primed ? "Yes" : "Filling")
                    ReadoutRow("Pending source", "\(metrics.pendingSourceFrames.formatted()) frames")
                    if metrics.auBlockFrames > 0 {
                        ReadoutRow("Capture / processing / ready", "\(metrics.captureQueueFrames.formatted()) / \(metrics.auInFlightFrames.formatted()) / \(metrics.processedQueueFrames.formatted()) frames")
                    }
                    if let low = metrics.queueLowFrames, let high = metrics.queueHighFrames {
                        ReadoutRow("Observed queue range · run", "\(low.formatted())–\(high.formatted()) frames")
                    }
                    Divider()
                    ReadoutRow("Measured clock difference", metrics.clockEstimateValid ? "\(number(Double(metrics.measuredClockDifferencePPM))) ppm" : "Unavailable")
                    ReadoutRow("Correction command", "\(number(Double(metrics.driftPPM))) ppm")
                    ReadoutRow("Applied correction", "\(number(Double(metrics.appliedDriftPPM))) ppm")
                    ReadoutRow("Saturated callbacks", "\(counters.value(\.driftSaturatedCallbacks).formatted())")
                    ReadoutRow("Held / limited callbacks", "\(counters.value(\.driftHeldCallbacks).formatted()) / \(counters.value(\.driftLimitedCallbacks).formatted())")
                    ReadoutRow("Refill threshold", "\(metrics.refillThresholdFrames.formatted()) frames")
                    ReadoutRow("Rebuffer events", "\(counters.value(\.rebufferEvents).formatted())")
                    ReadoutRow("Recentered frames", "\(counters.value(\.recenterFrames).formatted())")
                }
            }
            InfoGroupBox("Audio Unit processing", message: "Declared plugin signal latency and measured processing wall time describe different things. Wall time includes scheduling and preemption; it is not added to signal delay or equivalent to CPU utilization. Over-budget blocks and late wakes are clues, not proof of an audible glitch. The helper waits for a signaled full block rather than repeatedly sleeping. Wake delay measures notification to worker resume, excluding legitimate idle time. A Mach real-time policy is requested on its dedicated thread; the result below is the setup result, not a guarantee or continuous policy audit. Audio workgroup integration remains pending.\n\nWith 32-frame blocks at 48 kHz, one block is only 0.67 ms. Whole-chain bypass still renders plugins. Switching processing off live retains the helper; Stop and Start with processing off uses the direct bridge without plugin loading. Reset counters before comparisons. Startup filling is expected; subsequent lost frames remain visible even if they are difficult to hear.") {
                VStack(spacing: 8) {
                    ReadoutRow("Processing path", metrics.auBlockBudgetNanoseconds > 0 ? "AU helper" : "Direct bridge")
                    if let status = metrics.auSchedulingStatus {
                        ReadoutRow("Render thread scheduling", status == 0 ? "Real-time policy accepted" : (status == -1 ? "Not configured yet" : "QoS fallback · Mach status \(status)"))
                        ReadoutRow("Worker wake method", "Signaled queue readiness")
                    }
                    ReadoutRow("Effect DSP", metrics.effectsProcessingEnabled ? (metrics.chainBypassed ? "Rendering · dry bypass" : "Enabled") : "Off · dry forwarding")
                    ReadoutRow("Processed frames", "\(counters.value(\.auProcessedFrames).formatted())")
                    ReadoutRow("Effect latency applied", "\(number(Double(metrics.auLatencySeconds) * 1000)) ms")
                    ReadoutRow("Block size", "\(metrics.auBlockFrames.formatted()) frames")
                    ReadoutRow("Processing budget per block", milliseconds(metrics.auBlockBudgetNanoseconds))
                    ReadoutRow("Timed blocks", "\(counters.value(\.auRenderBlocks).formatted())")
                    ReadoutRow("Processing time · last", milliseconds(metrics.auLastRenderNanoseconds))
                    ReadoutRow("Processing time · mean", counters.value(\.auRenderBlocks) > 0 ? "\(number(Double(counters.value(\.auRenderNanoseconds)) / Double(counters.value(\.auRenderBlocks)) / 1e6)) ms" : "Unavailable")
                    if counters.value(\.auRenderBlocks) > 0, metrics.auBlockBudgetNanoseconds > 0 {
                        ReadoutRow("Mean block allowance used · wall time", "\((Double(counters.value(\.auRenderNanoseconds)) / Double(counters.value(\.auRenderBlocks)) / Double(metrics.auBlockBudgetNanoseconds) * 100).formatted(.number.precision(.fractionLength(0))))%")
                    }
                    ReadoutRow("Processing time · maximum run", milliseconds(metrics.auMaxRenderNanoseconds))
                    ReadoutRow("Over-budget blocks", "\(counters.value(\.auRenderOverBudgetBlocks).formatted())")
                    ReadoutRow("Late worker wakeups", "\(counters.value(\.auWorkerLateWakeups).formatted()) / \(counters.value(\.auWorkerWaits).formatted())")
                    ReadoutRow("Maximum signal-to-wake delay · run", milliseconds(metrics.auMaxWorkerWakeLatenessNanoseconds))
                }
            }
            InfoGroupBox("Signal levels", message: "Full-scale sample counts cover the current measurement window and indicate signal level. Digital attenuation cannot repair clipping that happened during capture. Stereo meter counts are shown as Mix L / Mix R; raw input and physical output counts refer to device-side samples.") {
                VStack(spacing: 8) {
                    ReadoutRow("Input full-scale samples · L / R", counters.pairs(metrics.inputLevels.map(\.clippedSamples), baseline?.inputLevels.map(\.clippedSamples)))
                    ReadoutRow("Output full-scale samples · L / R", counters.pairs(metrics.outputLevels.map(\.clippedSamples), baseline?.outputLevels.map(\.clippedSamples)))
                    ReadoutRow("Raw input full-scale samples", counters.pairs(metrics.rawInputClips, baseline?.rawInputClips))
                    ReadoutRow("Physical output full-scale samples", "\(counters.value(\.physicalOutputClips).formatted())")
                    ReadoutRow("Physical output peak", metrics.physicalOutputPeak > 0
                        ? String(format: "%.0f dB", 20 * log10(Double(metrics.physicalOutputPeak))) : "−∞ dB")
                }
            }
        }
    }
    private func rate(_ value: Double) -> String {
        let kHz = value / 1000
        return "\(kHz.formatted(.number.precision(.fractionLength(kHz.rounded() == kHz ? 0 : 1)))) kHz"
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    private func milliseconds(_ value: UInt64) -> String { "\(number(Double(value) / 1e6)) ms" }
}
