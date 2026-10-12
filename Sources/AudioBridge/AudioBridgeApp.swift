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
                HStack {
                    Text("Audio Bridge").font(.headline)
                    Spacer()
                    InfoButton(title: "Bridge status", message: model.bridgeStatusHelp)
                }
                RoutingStatusLabel(model: model)
                if model.routingRequested, let started = model.routingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Running for \(elapsed(context.date.timeIntervalSince(started)) )")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Input: \(endpointName(.input))")
                SignalMeters(model: model, direction: .input)
                Text("Output: \(endpointName(.output))")
                SignalMeters(model: model, direction: .output)
                OutputDeviceVolumeControl(model: model, allowsDigitalFallback: false)
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
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.error {
                        HStack {
                            Label("Settings need attention", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            InfoButton(title: "Settings error", message: error)
                        }
                    }
                    endpointPicker(.input)
                    endpointPicker(.output)
                    HStack {
                        Button("Apply interface buffer requests") { model.applyDeviceBufferDrafts() }
                            .disabled(!model.canEditSelections || model.changingDeviceBuffer)
                        InfoButton(title: "Apply interface buffers", message: "Stop routing before applying both device-buffer drafts. Drivers may round or reject requests; Current buffer shows readback. The software FIFO reserve is saved separately and takes effect next Start.\n\nLast result: \(model.deviceBufferMessage ?? "No request applied this session")")
                    }
                    InfoGroupBox("Device access", message: "Exclusive access requests Core Audio hog mode for both selected devices while routing. Some drivers do not support it; Start reports a device-specific failure if either request fails. Stop releases ownership after callback teardown. Device volume remains separate from digital gain.\n\nCurrent request: \(model.exclusiveAccessEnabled ? "Exclusive" : "Shared").") {
                        Toggle("Request exclusive access while routing", isOn: Binding(
                            get: { model.exclusiveAccessEnabled },
                            set: { model.setExclusiveAccessEnabled($0) }
                        )).disabled(!model.canEditSelections)
                    }
                    BufferSettings(model: model)
                    Button(model.refreshing ? "Refreshing…" : "Refresh devices and permission") { model.refresh() }
                        .disabled(model.refreshing)
                }.padding()
            }.tabItem { Label("Audio", systemImage: "hifispeaker") }.tag("Audio")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                    VStack(alignment: .leading, spacing: 14) {
                        InfoGroupBox("Application", message: "Interface debug information adds queue, drift and timing details to the main controls. It starts disabled at launch. Copy Status always contains the complete technical report. Device export includes identifiers and properties, with no audio samples or plugin state.") {
                            VStack(spacing: 8) {
                                ReadoutRow("Status", model.status)
                                ReadoutRow("Version / build", "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") / \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")")
                                ReadoutRow("Microphone permission", model.permission)
                                ReadoutRow("Bundle", Bundle.main.bundlePath).font(.caption)
                                Divider()
                                Toggle("Show debug information in the interface", isOn: $model.showDebugInformation)
                                HStack {
                                    Button("Copy status") { model.copyStatus() }
                                    Button("Export device facts…") { model.exportProbe() }
                                    Spacer()
                                    Button("Refresh") { model.refresh() }.disabled(model.refreshing)
                                }
                            }
                        }
                        LiveEngineDiagnostics(telemetry: model.telemetry)
                        InfoGroupBox("Recovery", message: "Desired routing and observed delivery are separate. Manual Stop cancels retries and persists stopped intent. Recoverable failures retry the same selected devices indefinitely with bounded backoff. Permission and configuration faults require action. The supervisor's backoff resets after 20 healthy seconds, separately from the five-second display-warning recovery.") {
                            VStack(spacing: 8) {
                                ReadoutRow("Desired routing", model.recovery.desired ? "On" : "Off")
                                ReadoutRow("Resume at launch", model.resumeAtLaunch ? "On" : "Off")
                                ReadoutRow("Retry stage", "\(model.recovery.attempts)")
                                if let fault = model.routingFault { ReadoutRow("Current fault", fault).foregroundStyle(.red) }
                                if let fault = model.lastRecoveryFault { ReadoutRow("Last recovery fault", fault) }
                                DisclosureGroup("Session history") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(model.recoveryHistory.enumerated()), id: \.offset) { _, event in
                                            Text(event).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }.padding(.top, 8)
                                }
                            }
                        }
                        if !model.catalog.issues.isEmpty {
                            InfoGroupBox("Catalog issues", message: "These are errors returned while reading Core Audio device properties. Unknown properties remain unknown and are not replaced with invented capability values. Refresh retries catalog discovery.") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(model.catalog.issues.enumerated()), id: \.offset) { _, issue in
                                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        DisclosureGroup {
                            VStack(spacing: 14) {
                                ForEach(model.catalog.devices) { device in
                                    InfoGroupBox(device.name, message: "These are driver-reported capabilities and stream formats. Device UID is the saved selection identity; runtime stream identifiers may change. This read-only report does not open or test audio delivery. Expand stream rows to inspect their virtual and physical formats.") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            deviceDetails(device)
                                            ForEach(Array(device.issues.enumerated()), id: \.offset) { _, issue in
                                                Text(issue).font(.caption).foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                }
                                if model.catalog.devices.isEmpty { Text("No devices discovered") }
                            }.padding(.top, 8)
                        } label: {
                            Text("Device catalog (\(model.catalog.devices.count))").font(.title3.bold())
                        }
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
                    Text("Audio configures devices, exclusive access and buffers. Routing patches channels. Effects configures Audio Units. General controls microphone permission, login, resume and visible tabs. Remote documents API and OSC endpoints. Diagnostics contains Copy Status and technical counters.")
                    Text("Separate interface buffers and the bridge FIFO are intentional: the first is configured by each device driver; the second is Audio Bridge's software reserve. Matching nominal sample rates are currently required. Independent device clocks are handled by adaptive drift correction.")
                }.padding()
            }.tabItem { Label("About", systemImage: "info.circle") }.tag("About")
        }
        .frame(minWidth: 760, minHeight: 560)
        .groupBoxStyle(SettingsGroupBoxStyle())
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
        let issue = direction == .input ? model.inputIssue : model.outputIssue
        let explanation = "Select this endpoint explicitly by its saved Core Audio identity. Stop routing to change devices or interface buffers. Input and output currently require matching nominal sample rates; their independent clocks and buffer sizes remain separate. Buffer drafts start at 64 frames when supported and change hardware only after Apply. Drivers may round or reject requests. For microphone-to-speaker checks, keep speaker volume low to avoid acoustic feedback.\n\n" + (issue.map { "Configuration: \($0)" } ?? "")
        return InfoGroupBox(direction.rawValue.capitalized + " device", message: explanation) {
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
            }.padding(6)
        }
    }
    private func deviceDetails(_ device: DeviceFacts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ReadoutRow("UID", device.uid).font(.caption)
            ReadoutRow("Transport", device.transport ?? "Unknown")
            ReadoutRow("Alive", device.alive.map { $0 ? "Yes" : "No" } ?? "Unknown")
            ReadoutRow("Clock domain", device.clockDomain.map(String.init) ?? "Unknown")
            ReadoutRow("Nominal rate", rate(device.nominalSampleRate))
            ReadoutRow("Interface buffer", "\(device.bufferFrames.map(String.init) ?? "Unknown") frames")
            ReadoutRow("Available rates", device.availableSampleRates.map {
                $0.minimum == $0.maximum ? rate($0.minimum) : "\(rate($0.minimum))–\(rate($0.maximum))"
            }.joined(separator: ", "))
            ForEach(AudioDirection.allCases, id: \.self) { direction in
                Divider()
                ReadoutRow(direction.rawValue.capitalized + " channels", device.facts(for: direction).channelCount.map(String.init) ?? "Unknown")
                ForEach(device.facts(for: direction).streams, id: \.runtimeID) { stream in
                    DisclosureGroup("Stream · starting channel \(stream.startingChannel.map(String.init) ?? "Unknown")") {
                        VStack(spacing: 8) {
                            ReadoutRow("Virtual format", format(stream.virtualFormat))
                            ReadoutRow("Physical format", format(stream.physicalFormat))
                        }.font(.caption).padding(.top, 8)
                    }
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
        return "\(value.formatID) · \(rate(value.sampleRate)) · \(value.channels) channels · \(value.bitsPerChannel)-bit \(representation) · \(value.isNonInterleaved ? "planar" : "interleaved")"
    }
}
