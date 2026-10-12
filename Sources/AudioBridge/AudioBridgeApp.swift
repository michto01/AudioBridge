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
                if model.routingRequested, let started = model.routingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Running for \(elapsed(context.date.timeIntervalSince(started)) )")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let fault = model.routingFault { Text(fault).font(.caption).foregroundStyle(.red) }
                Divider()
                Text("Input: \(endpointName(.input))")
                SignalMeters(model: model, direction: .input)
                Text("Output: \(endpointName(.output))")
                SignalMeters(model: model, direction: .output)
                OutputDeviceVolumeControl(model: model)
                if let issue = model.inputIssue { Text(issue).font(.caption) }
                if let issue = model.outputIssue { Text(issue).font(.caption) }
                if !model.routingRequested, let reason = model.startUnavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    RoutingToggleButton(model: model)
                    FocusSettingsButton()
                    Button("Quit") { model.quit() }
                }
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
    private func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
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
    @State private var selectedTab = "Bridge"
    var body: some View {
        TabView(selection: $selectedTab) {
            PlaybackView(model: model, selectAudio: { selectedTab = "Audio" })
                .tabItem { Label("Bridge", systemImage: "arrow.left.arrow.right") }.tag("Bridge")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    endpointPicker(.input)
                    endpointPicker(.output)
                    HStack {
                        Button("Apply interface buffer requests") { model.applyDeviceBufferDrafts() }
                            .disabled(!model.canEditSelections || model.changingDeviceBuffer)
                        Text("Requires routing stopped. Queue reserve settings are saved separately and take effect next Start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GroupBox("Device access") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Request exclusive device access while routing", isOn: Binding(
                                get: { model.exclusiveAccessEnabled },
                                set: { model.setExclusiveAccessEnabled($0) }
                            )).disabled(!model.canEditSelections)
                            Text("Prevents most other audio apps from using the selected input and output while Audio Bridge is running. Some devices do not support exclusive access; Start will report if either request fails.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Status: \(model.routingRequested ? (model.routingTransitioning ? "Acquiring…" : (model.exclusiveAccessEnabled ? "Held while routing" : "Shared access")) : (model.exclusiveAccessEnabled ? "Requested on next Start" : "Off"))")
                                .font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    BufferSettings(model: model)
                    Text("For microphone-to-speaker checks, start with the Mac's volume low to avoid acoustic feedback. Output meters show local samples; system speaker volume is separate.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.refreshing ? "Refreshing…" : "Refresh devices and permission") { model.refresh() }
                        .disabled(model.refreshing)
                    if model.recovery.desired || model.routingRequested || model.routingTransitioning {
                        Text("Stop routing to change devices. Routing grid and gains can change live.").font(.caption)
                    }
                    Text("Recoverable failures retry the selected route. Resume and login options are in General.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.tabItem { Label("Audio", systemImage: "hifispeaker") }.tag("Audio")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Patches and cell gains can change live. Start/Stop is in Bridge.").font(.caption).foregroundStyle(.secondary)
                    MatrixSettings(model: model)
                }.padding()
            }.tabItem { Label("Routing", systemImage: "point.3.connected.trianglepath.dotted") }.tag("Routing")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AUEffectsView(model: model)
                }.padding()
            }.tabItem { Label("Effects", systemImage: "puzzlepiece.extension") }.tag("Effects")
            GeneralSettingsView(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("General")
            if model.showRemoteTab { RemoteSettingsView(remote: model.remoteControl).tabItem { Label("Remote", systemImage: "network") }.tag("Remote") }
            if model.showDiagnosticsTab {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.status).font(.headline)
                    if let metrics = model.engineSnapshot, metrics.recentGlitches {
                        GroupBox("Current delivery warning") {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(metrics.deliveryWarningReason ?? "Audio delivery was interrupted", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Clears after 5 seconds of healthy callbacks and no new lost frames · \(Int(min(5, metrics.glitchCleanSeconds)))/5 seconds clean. Cumulative loss counts remain below.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Desired routing: \(model.recovery.desired ? "on" : "off") · resume at launch: \(model.resumeAtLaunch ? "on" : "off") · recovery attempts: \(model.recovery.attempts)")
                    if let fault = model.lastRecoveryFault { Text("Last recovery fault: \(fault)").font(.caption) }
                    DisclosureGroup("Recovery history (this session)") {
                        ForEach(Array(model.recoveryHistory.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption)
                        }
                    }
                    Toggle("Show debug information in the interface", isOn: $model.showDebugInformation)
                    Text("Adds live buffer, drift, AU timing and detailed delay readouts to the interface. Copy Status always includes the technical diagnostics.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development") · bundle: \(Bundle.main.bundlePath)")
                        .font(.caption)
                    if let metrics = model.engineSnapshot {
                        Text("Input callbacks: \(metrics.inputCallbacks) · output callbacks: \(metrics.outputCallbacks)")
                        Text("Captured / rendered frames: \(metrics.inputFrames) / \(metrics.outputFrames)")
                        Text("FIFO: \(metrics.bufferedFrames) frames · prefill complete: \(metrics.primed ? "yes" : "no")")
                        Text("Underrun / overrun frames: \(metrics.underrunFrames) / \(metrics.overrunFrames) · format faults: \(metrics.formatFaults)")
                        Text("Engine rate: \((metrics.sampleRate / 1000).formatted(.number.precision(.fractionLength(0)))) kHz · measured clock difference: \(metrics.clockEstimateValid ? "\(metrics.measuredClockDifferencePPM.formatted(.number.precision(.fractionLength(1)))) ppm" : "unavailable") · correction command: \(metrics.driftPPM.formatted(.number.precision(.fractionLength(1)))) ppm")
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
            }.tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag("Diagnostics")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Audio Bridge").font(.title2)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                    Text("Quick start").font(.headline)
                    Text("1. In Audio, select the input and output by name. Check their sample rates and buffer settings.\n2. In Routing, choose a mono or stereo preset, then verify the physical channels.\n3. In Effects, add and configure optional Audio Units.\n4. Return to Bridge and press Start. Confirm fresh meters and a running status before relying on the route.")
                    Text("Audio Bridge mixes selected physical input channels to stereo, processes the optional stereo effect chain and copies the result to selected physical outputs. It does not record or transmit audio. Hardware timing and sustained unattended operation still require validation with your devices.")
                    Text("Settings guide").font(.headline)
                    Text("Audio configures devices, permission, exclusive access and buffers. Routing patches channels. Effects configures Audio Units. General controls login, resume and visible tabs. Remote documents API and OSC endpoints. Diagnostics contains Copy Status and technical counters.")
                    Text("Separate interface buffers and the bridge FIFO are intentional: the first is configured by each device driver; the second is Audio Bridge's software reserve. Matching nominal sample rates are currently required. Independent device clocks are handled by adaptive drift correction.")
                }.padding()
            }.tabItem { Label("About", systemImage: "info.circle") }.tag("About")
        }
        .frame(minWidth: 760, minHeight: 560)
        .padding().frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 680)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkPermission()
            if model.consumeSettingsRestoreRequest() {
                SettingsWindowFocus.requested = true
                DispatchQueue.main.async { SettingsWindowFocus.bringForward() }
            }
        }
        .onChange(of: model.showRemoteTab) { _, visible in
            if !visible && selectedTab == "Remote" { selectedTab = "General" }
        }
        .onChange(of: model.showDiagnosticsTab) { _, visible in
            if !visible && selectedTab == "Diagnostics" { selectedTab = "General" }
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
                    Text("\(device.facts(for: direction).channelCount.map(String.init) ?? "Unknown") channels · \(rate(device.nominalSampleRate))")
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
    private func rate(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        let kilohertz = value / 1000
        let precision = kilohertz.rounded() == kilohertz ? 0 : 1
        return "\(kilohertz.formatted(.number.precision(.fractionLength(precision)))) kHz"
    }
    private func format(_ value: StreamFormat?) -> String {
        guard let value else { return "unknown" }
        let representation = value.isFloat ? "float" : (value.isSignedInteger ? "signed int" : "other")
        return "\(value.formatID) \(value.sampleRate.formatted()) Hz / \(value.channels)ch / \(value.bitsPerChannel)-bit \(representation) / \(value.isNonInterleaved ? "planar" : "interleaved")"
    }
}
