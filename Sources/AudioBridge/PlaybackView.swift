import AudioBridgeCore
import SwiftUI

extension AppModel {
    var delayEstimate: DelayEstimate? {
        guard let s = engineSnapshot else { return nil }
        return DelayEstimate(input: s.delayInputDevice, output: s.delayOutputDevice, selection: s.delaySelection,
            sampleRate: s.sampleRate, captureQueue: s.captureQueueFrames, processedQueue: s.processedQueueFrames,
            inFlight: s.auInFlightFrames, lookahead: s.resamplerLookaheadFrames,
            auLatencySeconds: Double(s.auLatencySeconds), bypassed: s.chainBypassed,
            pendingSourceFrames: s.pendingSourceFrames)
    }
}

struct PlaybackView: View {
    @ObservedObject var model: AppModel
    let selectAudio: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio Bridge").font(.title3.weight(.semibold))
                        Text("Reliable audio routing for live production").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RoutingStatusLabel(model: model).font(.headline)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
                HStack(alignment: .center, spacing: 8) {
                    PlaybackEndpointCard(model: model, direction: .input, selectAudio: selectAudio)
                    Image(systemName: "arrow.right").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityLabel("routes to")
                    PlaybackEndpointCard(model: model, direction: .output, selectAudio: selectAudio)
                }
                if model.routingRequested, let started = model.routingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Running for \(elapsed(context.date.timeIntervalSince(started)))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if model.showDebugInformation, let s = model.engineSnapshot, model.routingRequested, s.recentGlitches {
                    Text("Delivery warning clears after 20 healthy seconds · \(Int(min(20, s.glitchCleanSeconds)))/20 s. Historical counters remain in Diagnostics.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    RoutingToggleButton(model: model)
                }
                if let fault = model.routingFault { Text(fault).foregroundStyle(.red) }
                if !model.routingRequested, let reason = model.startUnavailableReason {
                    Text("Start unavailable: \(reason)").font(.caption).foregroundStyle(.secondary)
                }
                DelayView(model: model)
                Text("Stop cancels recovery and stays stopped after relaunch. Configure devices and buffers in Audio, patches in Routing, plugins in Effects and launch behavior in General.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
    private func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

struct RoutingToggleButton: View {
    @ObservedObject var model: AppModel
    private var stopping: Bool { model.canStopRouting }
    var body: some View {
        Button {
            if stopping { model.stopRouting() } else { model.startRouting() }
        } label: {
            Label(stopping ? "Stop" : "Start", systemImage: stopping ? "stop.fill" : "play.fill")
        }
        .disabled(!stopping && !model.canStartRouting)
        .tint(stopping ? .red : .accentColor)
        .buttonStyle(.borderedProminent)
    }
}

private struct PlaybackEndpointCard: View {
    @ObservedObject var model: AppModel
    let direction: AudioDirection
    let selectAudio: () -> Void
    private var device: DeviceFacts? { model.device(direction) }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: selectAudio) {
                HStack(spacing: 12) {
                    if let device {
                        DeviceIcon(device: device, direction: direction, image: model.deviceIcons[device.uid])
                            .frame(width: 42, height: 42)
                    } else {
                        Image(systemName: direction == .input ? "mic" : "speaker.wave.2")
                            .font(.system(size: 28)).frame(width: 42, height: 42)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(direction == .input ? "INPUT DEVICE" : "OUTPUT DEVICE")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(device?.name ?? (model.endpoint(direction).uid == nil ? "Unconfigured" : "Selected device missing"))
                            .font(.headline).lineLimit(1).truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).contentShape(Rectangle())
                if let device {
                    Text("\(device.facts(for: direction).channelCount ?? 0) channels · \(rate(device.nominalSampleRate))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Device not connected").font(.caption).foregroundStyle(.secondary)
                }
                SignalMeters(model: model, direction: direction)
                GainControl(model: model, direction: direction)
                if direction == .output {
                    OutputDeviceVolumeControl(model: model)
                } else { Color.clear.frame(height: 32) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 285, alignment: .topLeading)
            .padding(3)
        }
        .frame(maxWidth: .infinity)
    }
    private func rate(_ value: Double?) -> String {
        guard let value else { return "Unknown rate" }
        let kilohertz = value / 1000
        let precision = kilohertz.rounded() == kilohertz ? 0 : 1
        return "\(kilohertz.formatted(.number.precision(.fractionLength(precision)))) kHz"
    }
}

private struct DelayView: View {
    @ObservedObject var model: AppModel
    @State private var bridgeSamples: [(Date, Double)] = []
    @State private var averagedBridgeMilliseconds: Double?
    @State private var delayAverageReady = false
    var body: some View {
        GroupBox("Delay & processing") {
            VStack(alignment: .leading, spacing: 8) {
                if let s = model.engineSnapshot, let estimate = model.delayEstimate {
                    Text(model.routingRequested ? (s.primed ? "Live estimate" : "Startup — estimate not steady") : "Last run snapshot")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(delayAverageReady
                        ? averagedBridgeMilliseconds.map { "Bridge + callback buffers: ~\(number($0)) ms average (5 s)" } ?? "Bridge + callback buffers: incomplete estimate"
                        : estimate.subtotalMilliseconds(categories: [.bridge, .callbackBuffer]).map { "Bridge + callback buffers: ~\(number($0)) ms · smoothing over 5 s" }
                            ?? "Bridge + callback buffers: incomplete estimate")
                        .font(.headline)
                    if model.showDebugInformation {
                    Text(estimate.subtotalMilliseconds(categories: [.deviceReported]).map { "Device-reported delay: \(number($0)) ms" } ?? "Device-reported delay: Unknown / incomplete")
                    Text(estimate.totalMilliseconds.map { "Combined accounting estimate: ~\(number($0)) ms" }
                        ?? "Combined known subtotal: \(number(estimate.milliseconds(estimate.knownFrames) ?? 0)) ms · incomplete")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Pending source audio: \(s.pendingSourceFrames) frames · capture \(s.captureQueueFrames), AU in flight \(s.auInFlightFrames), processed \(s.processedQueueFrames) (individual snapshots approximate)")
                        .font(.caption.monospacedDigit())
                    if let low = s.queueLowFrames, let high = s.queueHighFrames {
                        Text("Pending source range: \(low)–\(high) frames / \(number(Double(low) / s.sampleRate * 1000))–\(number(Double(high) / s.sampleRate * 1000)) ms")
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
                            Text("Measured input/output clock difference: \(s.clockEstimateValid ? "\(number(Double(s.measuredClockDifferencePPM))) ppm" : "unavailable") · correction command / applied: \(number(Double(s.driftPPM))) / \(number(Double(s.appliedDriftPPM))) ppm")
                            Text("Controller held: \(s.driftHeldCallbacks) · unity limited: \(s.driftLimitedCallbacks) callbacks")
                            Text("Correction command saturated: \(s.driftSaturatedCallbacks) callbacks")
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
                        Text("Estimate only. Actual end-to-end delay requires loopback measurement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Start routing to observe queues and AU processing times. No measured delay is available yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            guard let value = model.delayEstimate?.subtotalMilliseconds(categories: [.bridge, .callbackBuffer]) else { return }
            bridgeSamples = bridgeSamples.filter { date.timeIntervalSince($0.0) <= 5 } + [(date, value)]
            averagedBridgeMilliseconds = bridgeSamples.map(\.1).reduce(0, +) / Double(bridgeSamples.count)
            delayAverageReady = bridgeSamples.count >= 5
        }
        .onChange(of: model.routingStartedAt) { _, _ in bridgeSamples.removeAll(); averagedBridgeMilliseconds = nil; delayAverageReady = false }
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
}
