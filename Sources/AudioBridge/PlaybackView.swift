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
    var bridgeStatusHelp: String {
        var lines = ["Current status: \(status)"]
        if let fault = routingFault { lines.append(fault) }
        if let inputIssue { lines.append("Input: \(inputIssue)") }
        if let outputIssue { lines.append("Output: \(outputIssue)") }
        if !routingRequested, let reason = startUnavailableReason { lines.append("Start unavailable: \(reason)") }
        if routingRequested, let s = engineSnapshot, s.recentGlitches {
            lines.append("\(s.deliveryWarningReason ?? "Audio delivery was interrupted"). Clears after five healthy seconds. Diagnostics shows the loss counts and clean-time progress.")
        }
        lines.append("Start opens your explicitly selected route. Stop cancels recovery and stays stopped after relaunch. Click a device header to configure it in Audio. Set physical patches in Routing, plugins in Effects and launch behavior in General. Running confirms local callbacks, not upstream transport or downstream sound.")
        return lines.joined(separator: "\n\n")
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
                        Text("Audio Bridge").font(.title2.weight(.bold))
                        Text("Reliable audio routing for live production").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RoutingStatusLabel(model: model).font(.headline)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    InfoButton(title: "Bridge status", message: model.bridgeStatusHelp)
                }
                BridgeEndpointLayout {
                    PlaybackEndpointCard(model: model, direction: .input, selectAudio: selectAudio)
                    Image(systemName: "arrow.right").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityLabel("routes to")
                    PlaybackEndpointCard(model: model, direction: .output, selectAudio: selectAudio)
                }
                HStack {
                    RoutingToggleButton(model: model)
                    if model.routingRequested, let started = model.routingStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsed(context.date.timeIntervalSince(started)))
                                .monospacedDigit().foregroundStyle(.secondary)
                                .accessibilityLabel("Running for \(elapsed(context.date.timeIntervalSince(started)))")
                        }
                    }
                }
                DelayView(model: model)
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
        InfoGroupBox(direction == .input ? "Input" : "Output", message: endpointHelp) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: selectAudio) {
                HStack(spacing: 12) {
                    if let device {
                        DeviceIcon(device: device, direction: direction, image: model.deviceIcons[device.uid], size: 42)
                    } else {
                        Image(systemName: direction == .input ? "mic" : "speaker.wave.2")
                            .resizable().scaledToFit().frame(width: 42, height: 42)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device?.name ?? (model.endpoint(direction).uid == nil ? "Unconfigured" : "Selected device missing"))
                            .font(.headline).lineLimit(2).frame(height: 42, alignment: .leading)
                        if let device {
                            Text("\(device.facts(for: direction).channelCount ?? 0) channels · \(rate(device.nominalSampleRate))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Device not connected").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).contentShape(Rectangle())
                SignalMeters(model: model, direction: direction)
                if direction == .input { GainControl(model: model, direction: .input) }
                if direction == .output {
                    OutputDeviceVolumeControl(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(3)
        }
        .frame(maxWidth: .infinity)
    }
    private var endpointHelp: String {
        let shared = "Click the device name or icon to open Audio configuration. Meters show measured stereo Mix L/R peaks; CLIP is a signal-level indication and holds briefly. Inactive means routing is stopped or callbacks are not fresh. Digital trim changes both channels smoothly and cannot undo clipping already present at capture."
        return direction == .input ? shared : shared + "\n\nDevice volume controls the selected device's master volume and remains usable during exclusive access when the driver supports it. Digital output gain stays at 0 dB when device volume is writable. Otherwise the card offers digital gain as a fallback. Device volume is downstream of the software output meters. " + (model.outputDeviceVolumeError ?? "")
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
    @ObservedObject private var telemetry: EngineTelemetry
    @State private var bridgeSamples: [(Date, Double)] = []
    @State private var averagedBridgeMilliseconds: Double?
    @State private var delayAverageReady = false

    init(model: AppModel) {
        self.model = model
        telemetry = model.telemetry
    }

    var body: some View {
        InfoGroupBox("Delay", message: delayHelp) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Bridge + callback buffers").foregroundStyle(.secondary)
                    Spacer()
                    Text(bridgeMilliseconds.map { "~\(number($0)) ms" } ?? "—")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                }
                if model.showDebugInformation, let s = telemetry.snapshot, let estimate = model.delayEstimate {
                    Divider()
                    ReadoutRow("Device-reported delay", estimate.subtotalMilliseconds(categories: [.deviceReported]).map { "\(number($0)) ms" } ?? "Unknown")
                    ReadoutRow("Combined estimate", estimate.totalMilliseconds.map { "~\(number($0)) ms" } ?? "Incomplete")
                    ReadoutRow("Pending source", "\(s.pendingSourceFrames) frames")
                    ReadoutRow("AU block", "\(s.auBlockFrames) frames")
                    if s.auRenderBlocks > 0 {
                        ReadoutRow("AU mean processing time", "\(number(Double(s.auRenderNanoseconds) / Double(s.auRenderBlocks) / 1e6)) ms")
                    }
                    DisclosureGroup("Delay components") {
                        VStack(spacing: 8) {
                            ForEach(estimate.components) { row in
                                ReadoutRow(row.label, row.frames.map { "\(number(estimate.milliseconds($0) ?? 0)) ms · \(number($0)) frames" } ?? "Unknown")
                            }
                        }.font(.callout).padding(.top, 8)
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            guard model.routingRequested, model.engineSnapshot?.primed == true,
                  let value = model.delayEstimate?.subtotalMilliseconds(categories: [.bridge, .callbackBuffer]) else { return }
            bridgeSamples = bridgeSamples.filter { date.timeIntervalSince($0.0) <= 5 } + [(date, value)]
            averagedBridgeMilliseconds = bridgeSamples.map(\.1).reduce(0, +) / Double(bridgeSamples.count)
            delayAverageReady = bridgeSamples.count >= 5
        }
        .onChange(of: model.routingStartedAt) { _, _ in
            bridgeSamples.removeAll(); averagedBridgeMilliseconds = nil; delayAverageReady = false
        }
    }
    private var bridgeMilliseconds: Double? {
        delayAverageReady ? averagedBridgeMilliseconds : model.delayEstimate?.subtotalMilliseconds(categories: [.bridge, .callbackBuffer])
    }
    private var delayHelp: String {
        let observation = model.engineSnapshot.map {
            model.routingRequested ? ($0.primed ? "Live estimate, averaged over five seconds." : "Starting; the estimate is not steady yet.") : "Last run snapshot."
        } ?? "Start routing to obtain an estimate."
        return observation + "\n\nThe main value includes callback buffers, software queues, resampler lookahead and declared AU signal latency. Device and stream latency reports add a separate allowance; small buffers do not remove that internal delay. Missing reports remain unknown. Startup reserve is not added twice. AU processing wall time is performance telemetry and is not added to signal delay.\n\nActual end-to-end latency requires a loopback measurement. Enable interface debug information in Diagnostics for the accounting breakdown."
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
}
