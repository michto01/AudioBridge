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
                    Text(estimate.totalMilliseconds.map { "Estimated chain allowance: \(number($0)) ms" }
                        ?? "Known subtotal: \(number(estimate.milliseconds(estimate.knownFrames) ?? 0)) ms · incomplete")
                        .font(.headline)
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
                    Text("Estimate adds driver reports, callback buffer allowances, observed queues/in-flight block, FIR lookahead and AU signal latency. Startup fill is not added again. Unknown properties stay unknown. Block wall time includes scheduling/preemption and is not added to signal delay. This is not a measured end-to-end latency; that requires loopback.")
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
