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
        case .requiresApproval: return "Approval required in System Settings"
        case .notRegistered: return "Off"
        case .notFound: return "Service unavailable"
        @unknown default: return "Unknown service status"
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
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Start at login", isOn: Binding(get: { login.registered }, set: { login.setEnabled($0) }))
                .disabled(login.changing || (!login.available && !login.registered))
            Text("Login item: \(login.description)").font(.caption).foregroundStyle(.secondary)
            if !login.available {
                Text("Install AudioBridge.app in Applications before enabling login launch. Temporary build locations are not stable login targets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if login.status == .requiresApproval { Button("Open Login Items Settings") { login.openSystemSettings() } }
            if let error = login.error { Text(error).foregroundStyle(.red) }
            Divider()
            GroupBox("Privacy") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone permission: \(model.permission)")
                    HStack {
                        Button("Request microphone permission") { model.requestPermission() }
                            .disabled(!model.permissionCanBeRequested)
                        Button("Open Privacy Settings") { model.openPrivacySettings() }
                    }
                    Text("Permission is requested only when you press the button. Capture begins only after you press Start.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Settings tabs") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show Remote tab", isOn: Binding(get: { model.showRemoteTab }, set: { model.setVisibleTab("Remote", visible: $0) }))
                    Toggle("Show Diagnostics tab", isOn: Binding(get: { model.showDiagnosticsTab }, set: { model.setVisibleTab("Diagnostics", visible: $0) }))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Toggle("Resume routing when the app launches", isOn: Binding(get: { model.resumeAtLaunch }, set: { model.setResumeAtLaunch($0) }))
            Text("Press Start once after configuring your route. A deliberate Stop stays stopped across relaunch, even with resume enabled. Quit preserves the last routing intent.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Recoverable device and callback failures retry using the selected UIDs. Permission, configuration and unsafe teardown faults require action. No alternative output is selected.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().onAppear { model.checkPermission() }
        }
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}
