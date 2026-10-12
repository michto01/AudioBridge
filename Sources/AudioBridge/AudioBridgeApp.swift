import AudioBridgeStrings
import AppKit
import CoreServices
import UserNotifications
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
                    Text(L("Audio Bridge")).font(.headline)
                    Spacer()
                    InfoButton(title: L("Bridge status"), message: model.bridgeStatusHelp)
                }
                RoutingStatusLabel(model: model)
                if model.routingRequested, let started = model.routingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(L("Running for \(elapsed(context.date.timeIntervalSince(started)) )"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text(L("Input: \(endpointName(.input))"))
                SignalMeters(model: model, direction: .input)
                Text(L("Output: \(endpointName(.output))"))
                SignalMeters(model: model, direction: .output)
                OutputDeviceVolumeControl(model: model, allowsDigitalFallback: false)
                HStack {
                    RoutingToggleButton(model: model)
                    FocusSettingsButton()
                    Button(L("Quit")) { model.quit() }
                }
            }
            .padding().frame(width: 380)
            .environment(\.locale, Locale(identifier: model.interfaceLanguage))
        } label: {
            Image(nsImage: MenuStatusIcon.image(model.activity)).renderingMode(.original)
                .accessibilityLabel(L("Audio Bridge — \(model.status)"))
                .help(L("Audio Bridge — \(model.status)"))
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(model: model)
                .background(SettingsWindowCapture())
                .environment(\.locale, Locale(identifier: model.interfaceLanguage))
        }
    }
    private func endpointName(_ direction: AudioDirection) -> String {
        model.device(direction)?.name ?? (model.endpoint(direction).uid == nil ? "Unconfigured" : L("Selected device missing"))
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
        Button(L("Settings…")) { SettingsWindowFocus.show { openSettings() } }
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
private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
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
                .tabItem { Label(L("Bridge"), systemImage: "arrow.left.arrow.right") }.tag("Bridge")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.error {
                        HStack {
                            Label(L("Settings need attention"), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            InfoButton(title: L("Settings error"), message: error)
                        }
                    }
                    Picker(L("Audio settings"), selection: Binding(get: { model.simpleAudioMode }, set: { model.setSimpleAudioMode($0) })) {
                        Text(L("Simple")).tag(true)
                        Text(L("Expert")).tag(false)
                    }.pickerStyle(.segmented).disabled(!model.canEditSelections)
                    endpointPicker(.input)
                    endpointPicker(.output)
                    if model.simpleAudioMode {
                        InfoGroupBox(L("Shared device settings"), message: L("Simple mode requests the same hardware buffer on both devices. FIFO reserve and AU blocks are chosen automatically. Drivers must confirm the requested size; otherwise choose another value or switch to Expert. Apply requests the shared sample rate and buffer on both devices. It is a device-wide change that can affect other audio apps. A partial failure is reported; Start stays blocked until both readbacks match. Audio MIDI Setup remains available for driver-managed controls. Switching modes never changes hardware by itself. Expert settings are retained.")) {
                            Picker(L("Sample rate"), selection: Binding(get: { model.simpleSampleRate }, set: { model.setSimpleSampleRate($0) })) {
                                ForEach(model.simpleRateChoices, id: \.self) { rate in Text(L("\((rate / 1000).formatted()) kHz")).tag(rate) }
                                if !model.simpleRateChoices.contains(model.simpleSampleRate) { Text(L("Requested rate unavailable")).tag(model.simpleSampleRate) }
                            }.disabled(!model.canEditSelections)
                            Picker(L("Both devices"), selection: Binding(get: { model.simpleBufferFrames }, set: { model.setSimpleBufferFrames($0) })) {
                                ForEach(model.simpleBufferChoices, id: \.self) { Text(L("\($0) frames")).tag($0) }
                                if !model.simpleBufferChoices.contains(model.simpleBufferFrames) { Text(L("Requested buffer unavailable")).tag(model.simpleBufferFrames) }
                            }.disabled(!model.canEditSelections)
                        }
                    }
                    HStack {
                        Button(L("Apply device settings")) { model.applyDeviceBufferDrafts() }
                            .disabled(!model.canEditSelections || model.changingDeviceBuffer)
                        InfoButton(title: L("Apply interface buffers"), message: L("Stop routing before applying both device-buffer drafts. Drivers may round or reject requests; Current buffer shows readback. The software FIFO reserve is saved separately and takes effect next Start.\n\nLast result: \(model.deviceBufferMessage ?? "No request applied this session")"))
                    }
                    if model.changingDeviceBuffer { ProgressView(L("Applying device settings…")) }
                    else if model.simpleAudioMode, model.simpleSettingsIssue != nil {
                        Label(L("Apply required — both devices must confirm the shared settings"), systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                    } else if model.deviceBufferMessage != nil {
                        Label(L("Device settings read back"), systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    InfoGroupBox(L("Device access"), message: L("Exclusive access requests Core Audio hog mode for both selected devices while routing. Some drivers do not support it; Start reports a device-specific failure if either request fails. Stop releases ownership after callback teardown. Device volume remains separate from digital gain.\n\nCurrent request: \(model.exclusiveAccessEnabled ? "Exclusive" : "Shared").")) {
                        Toggle(L("Request exclusive access while routing"), isOn: Binding(
                            get: { model.exclusiveAccessEnabled },
                            set: { model.setExclusiveAccessEnabled($0) }
                        )).disabled(!model.canEditSelections)
                    }
                    if !model.simpleAudioMode {
                        BufferSettings(model: model)
                        InfoGroupBox(L("AU render block"), message: L("Automatic follows the larger interface buffer, up to 256 frames. An explicit block sets the AU maximum render size before resources are allocated. It must fit the FIFO reserve. Larger blocks reduce wake/render overhead but add batching delay. Smaller blocks cannot remove the capture device's batching delay and may increase CPU or overload some plugins. Changes take effect at the next Start.")) {
                            Picker(L("Block size"), selection: Binding(get: { model.customAUFrames ?? 0 }, set: { model.setAUFrames($0 == 0 ? nil : $0) })) {
                                Text(L("Automatic")).tag(UInt32(0))
                                ForEach([16, 32, 64, 128, 256, 512, 1024], id: \.self) { Text(L("\($0) frames")).tag(UInt32($0)) }
                            }.disabled(!model.canEditSelections)
                        }
                    }
                    Button(LT(model.refreshing ? "Refreshing…" : L("Refresh devices and permission"))) { model.refresh() }
                        .disabled(model.refreshing)
                }.padding()
            }.tabItem { Label(L("Audio"), systemImage: "hifispeaker") }.tag("Audio")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MatrixSettings(model: model)
                }.padding()
            }.tabItem { Label(L("Routing"), systemImage: "point.3.connected.trianglepath.dotted") }.tag("Routing")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AUEffectsView(model: model)
                }.padding()
            }.tabItem { Label(L("Effects"), systemImage: "puzzlepiece.extension") }.tag("Effects")
            GeneralSettingsView(model: model).tabItem { Label(L("General"), systemImage: "gearshape") }.tag("General")
            if model.showRemoteTab { RemoteSettingsView(remote: model.remoteControl).tabItem { Label(L("Remote"), systemImage: "network") }.tag("Remote") }
            if model.showDiagnosticsTab {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        InfoGroupBox(L("Application"), message: L("Interface debug information adds queue, drift and timing details to the main controls. It starts disabled at launch. Copy Status always contains the complete technical report. Device export includes identifiers and properties, with no audio samples or plugin state.")) {
                            VStack(spacing: 8) {
                                ReadoutRow(L("Status"), model.status)
                                ReadoutRow(L("Version / build"), L("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") / \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")"))
                                ReadoutRow(L("Microphone permission"), model.permission)
                                ReadoutRow(L("Bundle"), Bundle.main.bundlePath).font(.caption)
                                Divider()
                                Toggle(L("Show debug information in the interface"), isOn: $model.showDebugInformation)
                                HStack {
                                    Button(L("Copy status")) { model.copyStatus() }
                                    Button(L("Export device facts…")) { model.exportProbe() }
                                    Spacer()
                                    Button(L("Refresh")) { model.refresh() }.disabled(model.refreshing)
                                }
                            }
                        }
                        LiveEngineDiagnostics(telemetry: model.telemetry, effects: model.auChain.active)
                        InfoGroupBox(L("Recovery"), message: L("Desired routing and observed delivery are separate. Manual Stop cancels retries and persists stopped intent. Device loss or format changes latch a stop until explicit re-arming. Other recoverable failures retry the same selected devices with bounded backoff. Permission and configuration faults require action. The supervisor's backoff resets after 20 healthy seconds, separately from the five-second display-warning recovery.")) {
                            VStack(spacing: 8) {
                                ReadoutRow(L("Desired routing"), model.recovery.desired ? "On" : "Off")
                                ReadoutRow(L("Resume at launch"), model.resumeAtLaunch ? "On" : "Off")
                                ReadoutRow(L("Retry stage"), L("\(model.recovery.attempts)"))
                                if let fault = model.routingFault { ReadoutRow(L("Current fault"), fault).foregroundStyle(.red) }
                                if let fault = model.lastRecoveryFault { ReadoutRow(L("Last recovery fault"), fault) }
                                DisclosureGroup(L("Session history")) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(model.recoveryHistory.enumerated()), id: \.offset) { _, event in
                                            Text(event).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }.padding(.top, 8)
                                }
                            }
                        }
                        if !model.catalog.issues.isEmpty {
                            InfoGroupBox(L("Catalog issues"), message: L("These are errors returned while reading Core Audio device properties. Unknown properties remain unknown and are not replaced with invented capability values. Refresh retries catalog discovery.")) {
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
                                    InfoGroupBox(device.name, message: L("These are driver-reported capabilities and stream formats. Device UID is the saved selection identity; runtime stream identifiers may change. This read-only report does not open or test audio delivery. Expand stream rows to inspect their virtual and physical formats.")) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            deviceDetails(device)
                                            ForEach(Array(device.issues.enumerated()), id: \.offset) { _, issue in
                                                Text(issue).font(.caption).foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                }
                                if model.catalog.devices.isEmpty { Text(L("No devices discovered")) }
                            }.padding(.top, 8)
                        } label: {
                            Text(L("Device catalog (\(model.catalog.devices.count))")).font(.title3.bold())
                        }
                    }.padding().textSelection(.enabled)
                }.tabItem { Label(L("Diagnostics"), systemImage: "stethoscope") }.tag("Diagnostics")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Audio Bridge")).font(.title2)
                    Text(L("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")"))
                    Text(L("Quick start")).font(.headline)
                    Text(L("1. In Audio, select the input and output by name. Check their sample rates and buffer settings.\n2. In Routing, choose a mono or stereo preset, then verify the physical channels.\n3. In Effects, add and configure optional Audio Units.\n4. Return to Bridge and press Start. Confirm fresh meters and a running status before relying on the route."))
                    Text(L("Audio Bridge mixes selected physical input channels to stereo, processes the optional stereo effect chain and copies the result to selected physical outputs. It does not record or transmit audio. Hardware timing and sustained unattended operation still require validation with your devices."))
                    Text(L("Settings guide")).font(.headline)
                    Text(L("Audio configures devices, exclusive access and buffers. Routing patches channels. Effects configures Audio Units. General controls microphone permission, login, resume and visible tabs. Remote documents API and OSC endpoints. Diagnostics contains Copy Status and technical counters."))
                    Text(L("Separate interface buffers and the bridge FIFO are intentional: the first is configured by each device driver; the second is Audio Bridge's software reserve. Matching nominal sample rates are currently required. Independent device clocks are handled by adaptive drift correction."))
                }.padding()
            }.tabItem { Label(L("About"), systemImage: "info.circle") }.tag("About")
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
        let explanation = L("Select this endpoint explicitly by its saved Core Audio identity. Stop routing to change devices or interface buffers. Input and output currently require matching nominal sample rates; their independent clocks and buffer sizes remain separate. Expert buffer drafts start from the driver’s current value, with a 64-frame fallback, and change hardware only after Apply. Drivers may round or reject requests. For microphone-to-speaker checks, keep speaker volume low to avoid acoustic feedback.\n\n") + (issue.map { L("Configuration: \($0)") } ?? "")
        return InfoGroupBox(LT(direction == .input ? "Input device" : "Output device"), message: explanation) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("Device"), selection: Binding(
                    get: { model.endpoint(direction).uid ?? "" },
                    set: { model.selectUID($0, direction: direction) }
                )) {
                    Text(L("Choose explicitly…")).tag("")
                    ForEach(available) { device in
                        Label {
                            Text(device.name)
                        } icon: {
                            DeviceIcon(device: device, direction: direction, image: model.deviceIcons[device.uid])
                        }.tag(device.uid)
                    }
                    if let uid = selected.uid, !available.contains(where: { $0.uid == uid }) {
                        Text(L("Selected device unavailable")).tag(uid)
                    }
                }.disabled(!model.canEditSelections)
                if let device {
                    if !model.simpleAudioMode { DeviceBufferControl(model: model, device: device).id(device.uid) }
                    else { ReadoutRow(L("Current buffer"), L("\(device.bufferFrames.map(String.init) ?? "Unknown") frames")) }
                    Text(L("\(device.facts(for: direction).channelCount.map(String.init) ?? "Unknown") channels · \(rate(device.nominalSampleRate))"))
                        .font(.caption)
                    if model.showDebugInformation, let range = device.bufferFrameRange {
                        Text(L("Supported buffer range: \(range.minimum.formatted())–\(range.maximum.formatted()) frames")).font(.caption)
                    }
                }
            }.padding(6)
        }
    }
    private func deviceDetails(_ device: DeviceFacts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ReadoutRow(L("UID"), device.uid).font(.caption)
            ReadoutRow(L("Transport"), device.transport ?? "Unknown")
            ReadoutRow(L("Alive"), device.alive.map { $0 ? "Yes" : "No" } ?? "Unknown")
            ReadoutRow(L("Clock domain"), device.clockDomain.map(String.init) ?? "Unknown")
            ReadoutRow(L("Nominal rate"), rate(device.nominalSampleRate))
            ReadoutRow(L("Interface buffer"), L("\(device.bufferFrames.map(String.init) ?? "Unknown") frames"))
            ReadoutRow(L("Available rates"), device.availableSampleRates.map {
                $0.minimum == $0.maximum ? rate($0.minimum) : L("\(rate($0.minimum))–\(rate($0.maximum))")
            }.joined(separator: L(", ")))
            ForEach(AudioDirection.allCases, id: \.self) { direction in
                Divider()
                ReadoutRow(LT(direction == .input ? "Input channels" : "Output channels"), device.facts(for: direction).channelCount.map(String.init) ?? "Unknown")
                ForEach(device.facts(for: direction).streams, id: \.runtimeID) { stream in
                    DisclosureGroup(L("Stream · starting channel \(stream.startingChannel.map(String.init) ?? "Unknown")")) {
                        VStack(spacing: 8) {
                            ReadoutRow(L("Virtual format"), format(stream.virtualFormat))
                            ReadoutRow(L("Physical format"), format(stream.physicalFormat))
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
        return L("\(kilohertz.formatted(.number.precision(.fractionLength(precision)))) kHz")
    }
    private func format(_ value: StreamFormat?) -> String {
        guard let value else { return "unknown" }
        let representation = value.isFloat ? "float" : (value.isSignedInteger ? L("signed int") : "other")
        return L("\(value.formatID) · \(rate(value.sampleRate)) · \(value.channels) channels · \(value.bitsPerChannel)-bit \(representation) · \(value.isNonInterleaved ? "planar" : "interleaved")")
    }
}
