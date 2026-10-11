import AppKit
import AudioBridgeCore
import AudioBridgeDiscovery
import AVFAudio
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var catalog = CatalogSnapshot(devices: [])
    @Published private(set) var selection = RouteSelection()
    @Published private(set) var error: String?
    @Published private(set) var permission = "Not checked"
    @Published private(set) var requestingPermission = false
    @Published private(set) var refreshing = false
    @Published private(set) var deviceIcons: [String: NSImage] = [:]
    private var iconCache: [URL: NSImage] = [:]
    private let store = SelectionStore()
    private let probeQueue = DispatchQueue(label: "cz.bytelab.audiobridge.discovery", qos: .utility)
    private var observation: CatalogObservation?
    private var pendingRefresh = false
    private var canSave = true
    var canEditSelections: Bool { canSave }

    init() {
        do { selection = try store.load() }
        catch { self.error = "Saved selections could not be read: \(error). Existing data is retained."; canSave = false }
        observation = CatalogObservation { [weak self] in self?.refresh() }
        observation?.watch([])
        checkPermission()
        refresh()
    }
    var inputIssue: String? { selection.input.issue(in: catalog.devices, direction: .input) }
    var outputIssue: String? { selection.output.issue(in: catalog.devices, direction: .output) }
    var status: String {
        if error != nil { return "Action required" }
        if selection.input.uid == nil || selection.output.uid == nil { return "Unconfigured" }
        if inputIssue != nil || outputIssue != nil { return "Selection requires attention" }
        return "Devices selected — routing not implemented"
    }
    var permissionCanBeRequested: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined && !requestingPermission
    }
    func endpoint(_ direction: AudioDirection) -> EndpointSelection {
        direction == .input ? selection.input : selection.output
    }
    func device(_ direction: AudioDirection) -> DeviceFacts? {
        guard let uid = endpoint(direction).uid else { return nil }
        return catalog.devices.first { $0.uid == uid }
    }
    func selectUID(_ uid: String, direction: AudioDirection) {
        var next = selection
        let endpoint = EndpointSelection(uid: uid.isEmpty ? nil : uid)
        if direction == .input { next.input = endpoint } else { next.output = endpoint }
        commit(next)
    }
    func selectChannel(_ channel: Int, lane: Int, direction: AudioDirection) {
        var next = selection
        var endpoint = self.endpoint(direction)
        if lane == 1 { endpoint.lane1 = channel == 0 ? nil : channel }
        else { endpoint.lane2 = channel == 0 ? nil : channel }
        if direction == .input { next.input = endpoint } else { next.output = endpoint }
        commit(next)
    }
    private func commit(_ next: RouteSelection) {
        guard canSave else { return }
        do { try store.save(next); selection = next; error = nil }
        catch { self.error = "Unable to save selections: \(error). Previous selections retained." }
    }
    func refresh() {
        checkPermission()
        guard !refreshing else { pendingRefresh = true; return }
        refreshing = true
        probeQueue.async { [weak self] in
            let result = Result { try CoreAudioCatalog.snapshot() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    var icons: [String: NSImage] = [:]
                    for device in snapshot.devices {
                        guard let url = device.iconURL, url.isFileURL else { continue }
                        if let image = self.iconCache[url] ?? NSImage(contentsOf: url).flatMap(Self.menuIcon) {
                            self.iconCache[url] = image
                            icons[device.uid] = image
                        }
                    }
                    self.deviceIcons = icons
                    self.observation?.watch(snapshot.devices)
                    self.catalog = CatalogSnapshot(devices: snapshot.devices,
                        issues: snapshot.issues + (self.observation?.issues ?? []))
                case .failure(let error):
                    self.catalog = CatalogSnapshot(devices: [], issues: ["Discovery failed: \(error)"])
                }
                self.refreshing = false
                if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
            }
        }
    }
    /// Native Picker menus can extract NSImage directly and bypass SwiftUI's frame.
    /// Rasterize at font size so both its intrinsic dimensions and pixels are bounded.
    private static func menuIcon(_ source: NSImage) -> NSImage? {
        let points = NSFont.systemFontSize
        let pixels = Int(ceil(points * 2))
        guard source.size.width > 0, source.size.height > 0,
              source.size.width.isFinite, source.size.height.isFinite,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                  pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let scale = min(CGFloat(pixels) / source.size.width, CGFloat(pixels) / source.size.height)
        let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let rect = NSRect(x: (CGFloat(pixels) - size.width) / 2,
                          y: (CGFloat(pixels) - size.height) / 2,
                          width: size.width, height: size.height)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        bitmap.size = NSSize(width: points, height: points)
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        return result
    }
    func checkPermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: permission = "Not requested"
        case .granted: permission = "Granted (capture has not been tested)"
        case .denied: permission = "Denied — enable Audio Bridge in System Settings → Privacy & Security → Microphone."
        @unknown default: permission = "Unknown — check System Settings"
        }
    }
    func requestPermission() {
        guard permissionCanBeRequested else { checkPermission(); return }
        requestingPermission = true
        AVAudioApplication.requestRecordPermission { [weak self] _ in
            Task { @MainActor in
                self?.requestingPermission = false
                self?.checkPermission()
            }
        }
    }
    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
    func exportProbe() {
        checkPermission()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AudioBridge-device-probe.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let report = ProbeReport(catalog: catalog, permissionStatus: permission,
                permissionContext: "AudioBridge.app; authorization status only, audio capture not tested.")
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch { self.error = "Unable to export device facts: \(error)" }
    }
}
