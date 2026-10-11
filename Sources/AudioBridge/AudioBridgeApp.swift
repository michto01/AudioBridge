import AppKit
import AudioBridgeCore
import SwiftUI

@main
@MainActor
struct AudioBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audio Bridge").font(.headline)
                Label(model.status, systemImage: "info.circle")
                Text("Experimental routing. Drift correction is not implemented.").foregroundStyle(.secondary)
                if let fault = model.routingFault { Text(fault).font(.caption).foregroundStyle(.red) }
                Divider()
                Text("Input: \(endpointName(.input))")
                GainControl(model: model, direction: .input)
                SignalMeters(model: model, direction: .input)
                Text("Output: \(endpointName(.output))")
                GainControl(model: model, direction: .output)
                SignalMeters(model: model, direction: .output)
                if let issue = model.inputIssue { Text(issue).font(.caption) }
                if let issue = model.outputIssue { Text(issue).font(.caption) }
                if !model.routingRequested, let reason = model.startUnavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Start") { model.startRouting() }.disabled(!model.canStartRouting)
                    Button("Stop") { model.stopRouting() }.disabled(!model.canStopRouting)
                    SettingsLink { Text("Settings…") }
                    Button("Quit") { model.quit() }
                }
            }
            .padding().frame(width: 380)
        } label: {
            Label("Audio Bridge — \(model.status)", systemImage: "waveform")
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(model: model)
        }
    }
    private func endpointName(_ direction: AudioDirection) -> String {
        model.device(direction)?.name ?? (model.endpoint(direction).uid == nil ? "Unconfigured" : "Selected device missing")
    }
}

@MainActor
private struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Experimental routing. Drift correction and rate conversion are not implemented; use for attended checks only.")
                        .foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    if let fault = model.routingFault { Text(fault).foregroundStyle(.red) }
                    Text(model.status).font(.headline)
                    HStack {
                        Button("Start") { model.startRouting() }.disabled(!model.canStartRouting)
                        Button("Stop") { model.stopRouting() }.disabled(!model.canStopRouting)
                    }
                    if !model.routingRequested, let reason = model.startUnavailableReason {
                        Text("Start unavailable: \(reason)").font(.caption).foregroundStyle(.secondary)
                    }
                    endpointPicker(.input)
                    endpointPicker(.output)
                    AUEffectsView(model: model)
                    BufferSettings(model: model)
                    Text("For microphone-to-speaker checks, start with the Mac's volume low to avoid acoustic feedback. Output meters show local samples; system speaker volume is separate.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Microphone permission: \(model.permission)")
                    HStack {
                        Button("Request microphone permission") { model.requestPermission() }
                            .disabled(!model.permissionCanBeRequested)
                        Button("Open Privacy Settings") { model.openPrivacySettings() }
                    }
                    Text("Permission is requested only when you press the button. Capture begins only after you press Start.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.refreshing ? "Refreshing…" : "Refresh devices and permission") { model.refresh() }
                        .disabled(model.refreshing)
                    if model.routingRequested || model.routingTransitioning {
                        Text("Stop routing to change devices or channels.").font(.caption)
                    }
                    Text("Matrix, drift correction and login controls are not yet implemented.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.tabItem { Label("Audio", systemImage: "waveform") }
            VStack(alignment: .leading, spacing: 12) {
                Text("Launch at login and automatic routing are not yet implemented.")
                Text("Device UIDs and explicit physical channels are saved on this Mac. A missing endpoint is never replaced with the system default.")
            }.padding().tabItem { Label("General", systemImage: "gearshape") }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.status).font(.headline)
                    Text("Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development") · bundle: \(Bundle.main.bundlePath)")
                        .font(.caption)
                    if let metrics = model.engineSnapshot {
                        Text("Input callbacks: \(metrics.inputCallbacks) · output callbacks: \(metrics.outputCallbacks)")
                        Text("Captured / rendered frames: \(metrics.inputFrames) / \(metrics.outputFrames)")
                        Text("FIFO: \(metrics.bufferedFrames) frames · prefill complete: \(metrics.primed ? "yes" : "no")")
                        Text("Underrun / overrun frames: \(metrics.underrunFrames) / \(metrics.overrunFrames) · format faults: \(metrics.formatFaults)")
                        Text("Engine rate: \(metrics.sampleRate.formatted()) Hz · drift correction: not implemented")
                        Text("Input clipped samples: \(metrics.inputLevels.map { String($0.clippedSamples) }.joined(separator: " / "))")
                        Text("Output clipped samples: \(metrics.outputLevels.map { String($0.clippedSamples) }.joined(separator: " / "))")
                        Text("Raw input full-scale samples: \(metrics.rawInputClips.map(String.init).joined(separator: " / "))")
                    }
                    Text("Microphone permission: \(model.permission)")
                    HStack {
                        Button("Refresh") { model.refresh() }.disabled(model.refreshing)
                        Button("Export device facts…") { model.exportProbe() }
                    }
                    Text("Export contains device identifiers and technical properties, never audio samples.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(model.catalog.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue).foregroundStyle(.red)
                    }
                    ForEach(model.catalog.devices) { device in
                        GroupBox(device.name) {
                            VStack(alignment: .leading, spacing: 5) {
                                deviceDetails(device)
                                ForEach(Array(device.issues.enumerated()), id: \.offset) { _, issue in
                                    Text(issue).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if model.catalog.devices.isEmpty { Text("No devices discovered; inspect errors or refresh.") }
                }.padding().textSelection(.enabled)
            }.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            VStack(alignment: .leading, spacing: 12) {
                Text("Audio Bridge").font(.title2)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") — Phase 2 experimental audio path")
                Text("The bridge does not record or transmit audio. Third-party Audio Units run separately and control their own behavior.")
            }.padding().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding().frame(width: 680, height: 580)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkPermission()
        }
    }
    private func endpointPicker(_ direction: AudioDirection) -> some View {
        let selected = model.endpoint(direction)
        let available = model.catalog.devices.filter { ($0.facts(for: direction).channelCount ?? 0) > 0 }
        let device = model.device(direction)
        return GroupBox(direction.rawValue.capitalized) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Device", selection: Binding(
                    get: { model.endpoint(direction).uid ?? "" },
                    set: { model.selectUID($0, direction: direction) }
                )) {
                    Text("Choose explicitly…").tag("")
                    ForEach(available) { device in
                        Label {
                            Text(device.name)
                        } icon: {
                            DeviceIcon(device: device, direction: direction, image: model.deviceIcons[device.uid])
                        }.tag(device.uid)
                    }
                    if let uid = selected.uid, !available.contains(where: { $0.uid == uid }) {
                        Text("Selected device unavailable").tag(uid)
                    }
                }.disabled(!model.canEditSelections)
                HStack {
                    channelPicker(direction, lane: 1, channels: device?.facts(for: direction).physicalChannels ?? [])
                    channelPicker(direction, lane: 2, channels: device?.facts(for: direction).physicalChannels ?? [])
                }.disabled(!model.canEditSelections)
                if direction == .input, device?.input.physicalChannels.count == 1 {
                    Button("Use mono input in both lanes") { model.duplicateMonoInput() }
                        .disabled(!model.canEditSelections)
                }
                GainControl(model: model, direction: direction)
                SignalMeters(model: model, direction: direction)
                if direction == .input, let raw = model.engineSnapshot?.rawInputClips, raw.contains(where: { $0 > 0 }) {
                    Text("Input reached full scale before trim. Digital attenuation cannot repair capture clipping.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let device {
                    Text("\(device.facts(for: direction).channelCount.map(String.init) ?? "Unknown") channels · \(rate(device.nominalSampleRate)) Hz · buffer \(device.bufferFrames.map(String.init) ?? "unknown") frames")
                        .font(.caption)
                    if let range = device.bufferFrameRange {
                        Text("Supported buffer range: \(range.minimum.formatted())–\(range.maximum.formatted()) frames").font(.caption)
                    }
                }
                if let issue = selected.issue(in: model.catalog.devices, direction: direction) { Text(issue).font(.caption) }
                if selected.lane1 != nil && selected.lane1 == selected.lane2 {
                    Text(direction == .input
                        ? "Both logical lanes explicitly use the same physical input channel (mono duplication)."
                        : "Both output lanes sum into one physical channel. Full-level inputs can clip.")
                        .font(.caption)
                }
            }.padding(6)
        }
    }
    private func channelPicker(_ direction: AudioDirection, lane: Int, channels: [Int]) -> some View {
        let selection = model.endpoint(direction)
        let channel = (lane == 1 ? selection.lane1 : selection.lane2) ?? 0
        return Picker("Lane \(lane)", selection: Binding(
            get: { let selected = model.endpoint(direction); return (lane == 1 ? selected.lane1 : selected.lane2) ?? 0 },
            set: { model.selectChannel($0, lane: lane, direction: direction) }
        )) {
            Text("Choose channel…").tag(0)
            ForEach(channels, id: \.self) { Text("Physical channel \($0)").tag($0) }
            if channel != 0 && !channels.contains(channel) { Text("Unavailable channel \(channel)").tag(channel) }
        }.disabled(model.endpoint(direction).uid == nil)
    }
    private func deviceDetails(_ device: DeviceFacts) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("UID: \(device.uid)")
            Text("Transport: \(device.transport ?? "unknown") · alive: \(device.alive.map(String.init) ?? "unknown") · clock domain: \(device.clockDomain.map(String.init) ?? "unknown")")
            Text("Nominal rate: \(rate(device.nominalSampleRate)) Hz · buffer: \(device.bufferFrames.map(String.init) ?? "unknown") frames")
            Text("Available rates (Hz): \(device.availableSampleRates.map { "\($0.minimum.formatted())–\($0.maximum.formatted())" }.joined(separator: ", "))")
            ForEach(AudioDirection.allCases, id: \.self) { direction in
                Text("\(direction.rawValue.capitalized): \(device.facts(for: direction).channelCount.map(String.init) ?? "unknown") channels")
                ForEach(device.facts(for: direction).streams, id: \.runtimeID) { stream in
                    Text("Stream starting channel \(stream.startingChannel.map(String.init) ?? "unknown"): virtual \(format(stream.virtualFormat)); physical \(format(stream.physicalFormat))")
                        .font(.caption)
                }
            }
        }.font(.callout)
    }
    private func rate(_ value: Double?) -> String { value.map { $0.formatted() } ?? "unknown" }
    private func format(_ value: StreamFormat?) -> String {
        guard let value else { return "unknown" }
        let representation = value.isFloat ? "float" : (value.isSignedInteger ? "signed int" : "other")
        return "\(value.formatID) \(value.sampleRate.formatted()) Hz / \(value.channels)ch / \(value.bitsPerChannel)-bit \(representation) / \(value.isNonInterleaved ? "planar" : "interleaved")"
    }
}
