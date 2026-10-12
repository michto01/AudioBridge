import AudioBridgeEngine
import Foundation
import SwiftUI

struct LiveEngineDiagnostics: View {
    @ObservedObject var telemetry: EngineTelemetry
    var body: some View {
        if let metrics = telemetry.snapshot {
            EngineDiagnosticsView(metrics: metrics)
        }
    }
}

/// Keep values in stable rows rather than making the operator parse sentences.
struct EngineDiagnosticsView: View {
    let metrics: EngineSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InfoGroupBox("Audio delivery", message: "Callback freshness and priming confirm local audio delivery. Lost-frame and format-fault counts remain cumulative for the run. A warning clears after five healthy seconds; queue recentering and rebuffer bookkeeping alone do not trigger it. Full-scale audio is shown separately as a signal level, not a delivery fault.") {
                VStack(spacing: 8) {
                    if metrics.recentGlitches {
                        ReadoutRow("Warning", metrics.deliveryWarningReason ?? "Delivery interrupted").foregroundStyle(.orange)
                        ReadoutRow("Recovery", "\(Int(min(5, metrics.glitchCleanSeconds))) / 5 seconds clean")
                        Divider()
                    }
                    ReadoutRow("Input callbacks", "\(metrics.inputCallbacks.formatted()) · \(metrics.inputActive ? "fresh" : "not fresh")")
                    ReadoutRow("Output callbacks", "\(metrics.outputCallbacks.formatted()) · \(metrics.outputActive ? "fresh" : "not fresh")")
                    ReadoutRow("Captured frames", "\(metrics.inputFrames.formatted())")
                    ReadoutRow("Rendered frames", "\(metrics.outputFrames.formatted())")
                    Divider()
                    ReadoutRow("Underrun frames", "\(metrics.underrunFrames.formatted())")
                    ReadoutRow("Overrun frames", "\(metrics.overrunFrames.formatted())")
                    ReadoutRow("Format faults", "\(metrics.formatFaults.formatted())")
                }
            }
            InfoGroupBox("Queues & clocks", message: "The timestamp-derived clock difference is separate from the occupancy controller's correction command. FIFO occupancy naturally changes between callbacks. A correction value alone is not evidence of lost audio or a physical clock fault. Pending source includes accepted capture not yet consumed or discarded; individual queue snapshots are approximate.") {
                VStack(spacing: 8) {
                    ReadoutRow("Sample rate", rate(metrics.sampleRate))
                    ReadoutRow("FIFO", "\(metrics.bufferedFrames.formatted()) / \(metrics.capacity.formatted()) frames")
                    ReadoutRow("Reserve target", "\(metrics.targetFrames.formatted()) frames")
                    ReadoutRow("Primed", metrics.primed ? "Yes" : "Filling")
                    ReadoutRow("Pending source", "\(metrics.pendingSourceFrames.formatted()) frames")
                    ReadoutRow("Capture / processing / ready", "\(metrics.captureQueueFrames.formatted()) / \(metrics.auInFlightFrames.formatted()) / \(metrics.processedQueueFrames.formatted()) frames")
                    if let low = metrics.queueLowFrames, let high = metrics.queueHighFrames {
                        ReadoutRow("Observed queue range", "\(low.formatted())–\(high.formatted()) frames")
                    }
                    Divider()
                    ReadoutRow("Measured clock difference", metrics.clockEstimateValid ? "\(number(Double(metrics.measuredClockDifferencePPM))) ppm" : "Unavailable")
                    ReadoutRow("Correction command", "\(number(Double(metrics.driftPPM))) ppm")
                    ReadoutRow("Applied correction", "\(number(Double(metrics.appliedDriftPPM))) ppm")
                    ReadoutRow("Saturated callbacks", "\(metrics.driftSaturatedCallbacks.formatted())")
                    ReadoutRow("Held / limited callbacks", "\(metrics.driftHeldCallbacks.formatted()) / \(metrics.driftLimitedCallbacks.formatted())")
                    ReadoutRow("Refill threshold", "\(metrics.refillThresholdFrames.formatted()) frames")
                    ReadoutRow("Rebuffer events", "\(metrics.rebufferEvents.formatted())")
                    ReadoutRow("Recentered frames", "\(metrics.recenterFrames.formatted())")
                }
            }
            InfoGroupBox("Audio Unit processing", message: "Declared plugin signal latency and measured processing wall time describe different things. Wall time includes scheduling and preemption, so it is not added to the signal-delay estimate. Over-budget blocks and late wakeups are performance clues; correlate them with delivery-loss counters and listening.") {
                VStack(spacing: 8) {
                    ReadoutRow("Processed frames", "\(metrics.auProcessedFrames.formatted())")
                    ReadoutRow("Declared plugin latency", "\(number(Double(metrics.auLatencySeconds) * 1000)) ms")
                    ReadoutRow("Block size", "\(metrics.auBlockFrames.formatted()) frames")
                    ReadoutRow("Timed blocks", "\(metrics.auRenderBlocks.formatted())")
                    ReadoutRow("Processing time · last", milliseconds(metrics.auLastRenderNanoseconds))
                    ReadoutRow("Processing time · mean", metrics.auRenderBlocks > 0 ? "\(number(Double(metrics.auRenderNanoseconds) / Double(metrics.auRenderBlocks) / 1e6)) ms" : "Unavailable")
                    ReadoutRow("Processing time · maximum", milliseconds(metrics.auMaxRenderNanoseconds))
                    ReadoutRow("Over-budget blocks", "\(metrics.auRenderOverBudgetBlocks.formatted())")
                    ReadoutRow("Late worker wakeups", "\(metrics.auWorkerLateWakeups.formatted()) / \(metrics.auWorkerWaits.formatted())")
                    ReadoutRow("Maximum wake lateness", milliseconds(metrics.auMaxWorkerWakeLatenessNanoseconds))
                }
            }
            InfoGroupBox("Signal levels", message: "Full-scale sample counts are cumulative signal-level indicators. Digital attenuation cannot repair clipping that happened during capture. Stereo meter counts are shown as Mix L / Mix R; raw input and physical output counts refer to device-side samples.") {
                VStack(spacing: 8) {
                    ReadoutRow("Input full-scale samples · L / R", metrics.inputLevels.map { $0.clippedSamples.formatted() }.joined(separator: " / "))
                    ReadoutRow("Output full-scale samples · L / R", metrics.outputLevels.map { $0.clippedSamples.formatted() }.joined(separator: " / "))
                    ReadoutRow("Raw input full-scale samples", metrics.rawInputClips.map { $0.formatted() }.joined(separator: " / "))
                    ReadoutRow("Physical output full-scale samples", "\(metrics.physicalOutputClips.formatted())")
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
