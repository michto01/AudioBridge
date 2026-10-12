import AppKit
import CoreServices
import AudioBridgeCore
import SwiftUI

@main
@MainActor
struct AudioBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audio Bridge").font(.headline)
                RoutingStatusLabel(model: model)
                Text("Experimental adaptive routing; hardware validation pending.").foregroundStyle(.secondary)
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
                    FocusSettingsButton()
                    Button("Quit") { model.quit() }
                }
                Button("Copy status") { model.copyStatus() }.font(.caption)
            }
            .padding().frame(width: 380)
        } label: {
            Image(nsImage: MenuStatusIcon.image(model.activity)).renderingMode(.original)
                .accessibilityLabel("Audio Bridge — \(model.status)")
                .help("Audio Bridge — \(model.status)")
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(model: model)
                .background(SettingsWindowCapture())
        }
    }
    private func endpointName(_ direction: AudioDirection) -> String {
        model.device(direction)?.name ?? (model.endpoint(direction).uid == nil ? "Unconfigured" : "Selected device missing")
    }
}

@MainActor
private struct FocusSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("Settings…") { SettingsWindowFocus.show { openSettings() } }
    }
}

@MainActor
private enum SettingsWindowFocus {
    static weak var window: NSWindow?
    static var requested = false
    static func show(_ open: () -> Void) {
        requested = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        open()
        bringForward()
        // SwiftUI may create/attach its native Settings window on the next turn.
        DispatchQueue.main.async { bringForward() }
    }
    static func bringForward() {
        guard requested, let window else { return }
        requested = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private struct SettingsWindowCapture: NSViewRepresentable {
    final class CaptureView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            SettingsWindowFocus.window = window
            SettingsWindowFocus.bringForward()
        }
    }
    func makeNSView(context: Context) -> NSView { CaptureView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AudioBridge", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            DispatchQueue.global(qos: .utility).async { _ = LSRegisterURL(bundle as CFURL, true) }
        }
    }
}

@MainActor
private struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            PlaybackView(model: model)
                .tabItem { Label("Playback", systemImage: "play.circle") }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    endpointPicker(.input)
                    endpointPicker(.output)
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
                    if model.recovery.desired || model.routingRequested || model.routingTransitioning {
                        Text("Stop routing to change devices. Routing grid and gains can change live.").font(.caption)
                    }
                    Text("Recoverable failures retry the selected route. Resume and login options are in General.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.tabItem { Label("Audio", systemImage: "waveform") }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Patches and cell gains can change live. Start/Stop is in Playback.").font(.caption).foregroundStyle(.secondary)
                    MatrixSettings(model: model)
                }.padding()
            }.tabItem { Label("Routing", systemImage: "point.3.connected.trianglepath.dotted") }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AUEffectsView(model: model)
                }.padding()
            }.tabItem { Label("Effects", systemImage: "slider.horizontal.3") }
            GeneralSettingsView(model: model).tabItem { Label("General", systemImage: "gearshape") }
            RemoteSettingsView(remote: model.remoteControl).tabItem { Label("Remote", systemImage: "network") }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.status).font(.headline)
                    Text("Desired routing: \(model.recovery.desired ? "on" : "off") · resume at launch: \(model.resumeAtLaunch ? "on" : "off") · recovery attempts: \(model.recovery.attempts)")
                    if let fault = model.lastRecoveryFault { Text("Last recovery fault: \(fault)").font(.caption) }
                    DisclosureGroup("Recovery history (this session)") {
                        ForEach(Array(model.recoveryHistory.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption)
                        }
                    }
                    Toggle("Show debug information in the interface", isOn: $model.showDebugInformation)
                    Text("Shows live queue, drift, AU timing and detailed delay readouts in Playback and Audio. Off by default at launch; diagnostic reports always include full details.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development") · bundle: \(Bundle.main.bundlePath)")
                        .font(.caption)
                    if let metrics = model.engineSnapshot {
                        Text("Input callbacks: \(metrics.inputCallbacks) · output callbacks: \(metrics.outputCallbacks)")
                        Text("Captured / rendered frames: \(metrics.inputFrames) / \(metrics.outputFrames)")
                        Text("FIFO: \(metrics.bufferedFrames) frames · prefill complete: \(metrics.primed ? "yes" : "no")")
                        Text("Underrun / overrun frames: \(metrics.underrunFrames) / \(metrics.overrunFrames) · format faults: \(metrics.formatFaults)")
                        Text("Engine rate: \(metrics.sampleRate.formatted()) Hz · correction: \(metrics.driftPPM.formatted(.number.precision(.fractionLength(1)))) ppm")
                        Text("Rebuffer events: \(metrics.rebufferEvents) · recentered frames discarded: \(metrics.recenterFrames)")
                        Text("Input clipped samples: \(metrics.inputLevels.map { String($0.clippedSamples) }.joined(separator: " / "))")
                        Text("Output clipped samples: \(metrics.outputLevels.map { String($0.clippedSamples) }.joined(separator: " / "))")
                        Text("Physical output peak: \(metrics.physicalOutputPeak.formatted()) · full-scale samples: \(metrics.physicalOutputClips)")
                        Text("Raw input full-scale samples: \(metrics.rawInputClips.map(String.init).joined(separator: " / "))")
                    }
                    Text("Microphone permission: \(model.permission)")
                    HStack {
                        Button("Refresh") { model.refresh() }.disabled(model.refreshing)
                        Button("Copy status") { model.copyStatus() }
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
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") — experimental supervised routing")
                Text("The bridge does not record or transmit audio. Third-party Audio Units run separately and control their own behavior.")
            }.padding().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 760, minHeight: 560)
        .padding().frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 680)
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
                if let device {
                    DeviceBufferControl(model: model, device: device).id(device.uid)
                    Text("\(device.facts(for: direction).channelCount.map(String.init) ?? "Unknown") channels · \(rate(device.nominalSampleRate)) Hz")
                        .font(.caption)
                    if model.showDebugInformation, let range = device.bufferFrameRange {
                        Text("Supported buffer range: \(range.minimum.formatted())–\(range.maximum.formatted()) frames").font(.caption)
                    }
                }
                if let issue = direction == .input ? model.inputIssue : model.outputIssue { Text(issue).font(.caption) }
            }.padding(6)
        }
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
