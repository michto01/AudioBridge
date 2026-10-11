import AudioBridgeCore
import SwiftUI

extension AppModel {
    var delayEstimate: DelayEstimate? {
        guard let s = engineSnapshot else { return nil }
        return DelayEstimate(input: s.delayInputDevice, output: s.delayOutputDevice, selection: s.delaySelection,
            sampleRate: s.sampleRate, captureQueue: s.captureQueueFrames, processedQueue: s.processedQueueFrames,
            inFlight: s.auInFlightFrames, lookahead: s.resamplerLookaheadFrames,
            auLatencySeconds: Double(s.auLatencySeconds), bypassed: s.chainBypassed)
    }
}

struct PlaybackView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RoutingStatusLabel(model: model).font(.headline)
                if let s = model.engineSnapshot, model.routingRequested, s.recentGlitches {
                    Text("Delivery warning clears after 20 healthy seconds · \(Int(min(20, s.glitchCleanSeconds)))/20 s. Historical counters remain in Diagnostics.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button { model.startRouting() } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(!model.canStartRouting)
                    Button { model.stopRouting() } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(!model.canStopRouting)
                    Spacer()
                    Button("Copy status") { model.copyStatus() }
                }
                if let fault = model.routingFault { Text(fault).foregroundStyle(.red) }
                if !model.routingRequested, let reason = model.startUnavailableReason {
                    Text("Start unavailable: \(reason)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(AudioDirection.allCases, id: \.self) { direction in
                    GroupBox("\(direction.rawValue.capitalized) · \(model.device(direction)?.name ?? "Unconfigured")") {
                        VStack(alignment: .leading, spacing: 8) {
                            GainControl(model: model, direction: direction)
                            SignalMeters(model: model, direction: direction)
                        }.padding(4)
                    }
                }
                DelayView(model: model)
                Text("Experimental routing; automatic recovery is not implemented. Configure devices/buffers in Audio, patches in Routing, and plugins in Effects.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
}

private struct DelayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("Delay & processing") {
            VStack(alignment: .leading, spacing: 8) {
                if let s = model.engineSnapshot, let estimate = model.delayEstimate {
                    Text(model.routingRequested ? (s.primed ? "Live estimate" : "Startup — estimate not steady") : "Last run snapshot")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(estimate.subtotalMilliseconds(categories: [.bridge, .callbackBuffer]).map { "Bridge + callback buffers: ~\(number($0)) ms" }
                        ?? "Bridge + callback buffers: incomplete estimate")
                        .font(.headline)
                    Text(estimate.subtotalMilliseconds(categories: [.deviceReported]).map { "Device-reported delay: \(number($0)) ms" } ?? "Device-reported delay: Unknown / incomplete")
                    Text(estimate.totalMilliseconds.map { "Combined accounting estimate: ~\(number($0)) ms" }
                        ?? "Combined known subtotal: \(number(estimate.milliseconds(estimate.knownFrames) ?? 0)) ms · incomplete")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Capture queue \(s.captureQueueFrames) · AU in flight \(s.auInFlightFrames) · processed queue \(s.processedQueueFrames) frames")
                        .font(.caption.monospacedDigit())
                    if let low = s.queueLowFrames, let high = s.queueHighFrames {
                        Text("Queue + in-flight range: \(low)–\(high) frames / \(number(Double(low) / s.sampleRate * 1000))–\(number(Double(high) / s.sampleRate * 1000)) ms")
                            .font(.caption.monospacedDigit())
                    }
                    if s.auRenderBlocks > 0 {
                        Text("AU block wall time: last \(number(Double(s.auLastRenderNanoseconds) / 1e6)), mean \(number(Double(s.auRenderNanoseconds) / Double(s.auRenderBlocks) / 1e6)), max \(number(Double(s.auMaxRenderNanoseconds) / 1e6)) ms")
                            .font(.caption.monospacedDigit())
                    } else { Text("AU block timing: awaiting processing").font(.caption) }
                    Text("Processing block: \(s.auBlockFrames) frames / \(number(Double(s.auBlockFrames) / s.sampleRate * 1000)) ms · \(s.auRenderBlocks) blocks timed")
                        .font(.caption.monospacedDigit())
                    DisclosureGroup("Buffer delivery diagnostics") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Drift command / applied: \(number(Double(s.driftPPM))) / \(number(Double(s.appliedDriftPPM))) ppm")
                            Text("Controller held: \(s.driftHeldCallbacks) · unity limited: \(s.driftLimitedCallbacks) callbacks")
                            Text("Current refill threshold: \(s.refillThresholdFrames) frames")
                            Text("AU blocks over duration budget: \(s.auRenderOverBudgetBlocks) / \(s.auRenderBlocks)")
                            Text("Polling wakeups late by more than a block: \(s.auWorkerLateWakeups) / \(s.auWorkerWaits)")
                            Text("Maximum wake lateness: \(number(Double(s.auMaxWorkerWakeLatenessNanoseconds) / 1e6)) ms")
                            Text("Wall time includes preemption. Counters are clues, not proof of an audible glitch or measured clock skew. Applied correction is the last callback sample; zero while refilling.")
                                .foregroundStyle(.secondary)
                        }.font(.caption.monospacedDigit()).padding(.top, 4)
                    }
                    DisclosureGroup("Delay breakdown") {
                        VStack(spacing: 5) {
                            ForEach(estimate.components) { row in
                                HStack {
                                    Text(row.label)
                                    Spacer()
                                    Text(row.frames.map { "\(number($0)) fr · \(number(estimate.milliseconds($0) ?? 0)) ms" } ?? "Unknown")
                                        .monospacedDigit()
                                }.font(.caption)
                            }
                        }.padding(.top, 4)
                    }
                    Text("Small callback buffers reduce the bridge allowance; they do not remove internal latency reported by the device/stream. The combined estimate includes those reports. Startup fill is not added again. Unknown properties stay unknown. AU wall processing time is separate. True end-to-end latency requires loopback measurement.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Start routing to observe queues and AU processing times. No measured delay is available yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
}
