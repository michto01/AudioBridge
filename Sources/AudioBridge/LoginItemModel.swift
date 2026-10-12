import AudioBridgeStrings
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status = SMAppService.Status.notRegistered
    @Published private(set) var error: String?
    @Published private(set) var changing = false
    init() { refresh() }
    var registered: Bool { status == .enabled || status == .requiresApproval }
    var available: Bool {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath()
        // Disposable builds cannot be reliable login targets. No automatic copy/install.
        return url.pathExtension == "app" && (url.path.hasPrefix("/Applications/")
            || url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"))
    }
    var description: String {
        switch status {
        case .enabled: return "Enabled"
        case .requiresApproval: return L("Approval required in System Settings")
        case .notRegistered: return "Off"
        case .notFound: return L("Service unavailable")
        @unknown default: return L("Unknown service status")
        }
    }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        guard !changing, (!enabled || available) else { return }
        changing = true; error = nil
        Task { @MainActor in
            defer { changing = false; refresh() }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var login = LoginItemModel()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InfoGroupBox(L("Language"), message: L("Choose the operator interface language. Device and plugin names stay as supplied by their drivers. Copy Status, HTTP and OSC contracts remain in English for support and integration.")) {
                    Picker(L("Language"), selection: Binding(get: { model.interfaceLanguage }, set: { model.setInterfaceLanguage($0) })) {
                        Text(L("English")).tag("en")
                        Text(L("Čeština")).tag("cs")
                    }
                }
                InfoGroupBox(L("Device error notifications"), message: L("A lost or changed device stops routing and latches a re-arm requirement. Reconnect does not restart audio. Enable macOS notifications here; the Bridge error remains visible even if notification permission is denied. Remote Start cannot clear this safety latch.")) {
                    Toggle(L("Notify when a device stops the bridge"), isOn: Binding(get: { model.deviceErrorNotifications }, set: { model.setDeviceErrorNotifications($0) }))
                    ReadoutRow(L("Notification permission"), model.notificationStatus)
                }
                InfoGroupBox(L("Launch & recovery"), message: launchHelp) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle(L("Start at login"), isOn: Binding(get: { login.registered }, set: { login.setEnabled($0) }))
                                .disabled(login.changing || (!login.available && !login.registered))
                            Spacer()
                            Text(LT(login.description)).font(.caption).foregroundStyle(.secondary)
                        }
                        if login.status == .requiresApproval { Button(L("Open Login Items Settings")) { login.openSystemSettings() } }
                        if let error = login.error { Text(error).foregroundStyle(.red) }
                        Toggle(L("Resume routing when the app launches"), isOn: Binding(get: { model.resumeAtLaunch }, set: { model.setResumeAtLaunch($0) }))
                    }
                }
                InfoGroupBox(L("Microphone permission"), message: L("Permission is requested only when you press Request. Capture begins when the configured bridge starts. If macOS retains a stale permission after rebuilding this ad-hoc signed app, quit it, toggle its entry in Privacy Settings and reopen the same bundle.")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ReadoutRow(L("Permission"), model.permission)
                        HStack {
                            Button(L("Request permission")) { model.requestPermission() }.disabled(!model.permissionCanBeRequested)
                            Button(L("Open Privacy Settings")) { model.openPrivacySettings() }
                        }
                    }
                }
                InfoGroupBox(L("Settings tabs"), message: L("Show the Remote tab to configure HTTP and OSC. Hiding it does not stop enabled listeners. Show Diagnostics for device identities, delivery counts, Copy Status and the interface debug toggle.")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L("Show Remote tab"), isOn: Binding(get: { model.showRemoteTab }, set: { model.setVisibleTab("Remote", visible: $0) }))
                        Toggle(L("Show Diagnostics tab"), isOn: Binding(get: { model.showDiagnosticsTab }, set: { model.setVisibleTab("Diagnostics", visible: $0) }))
                    }
                }
            }.padding().onAppear { model.checkPermission(); model.refreshNotificationStatus() }
        }
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
    private var launchHelp: String {
        let installation = login.available ? L("This bundle is eligible for login registration.") : L("Install AudioBridge.app in Applications before enabling login launch. Temporary build locations are not stable login targets.")
        return installation + L("\n\nLogin item: \(login.description).\n\nAfter configuring your route, press Start once to save running intent. A deliberate Stop stays stopped across relaunch, even with resume enabled. Quit preserves the last intent. Device loss or format changes require explicit re-arming. Other recoverable callback failures retry the selected UIDs; permission, configuration and unsafe teardown faults require action. No alternative output is selected.")
    }
}
