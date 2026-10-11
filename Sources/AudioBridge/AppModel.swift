import AppKit
import AudioBridgeCore
import AudioBridgeDiscovery
import AudioBridgeEngine
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
    @Published private(set) var routingRequested = false
    @Published private(set) var routingTransitioning = false
    @Published private(set) var engineSnapshot: EngineSnapshot?
    @Published private(set) var routingFault: String?
    @Published private(set) var bufferProfile: BufferProfile = .balanced
    @Published private(set) var customBufferFrames: UInt32?
    @Published private(set) var inputTrim: Double = 0
    @Published private(set) var outputGain: Double = 0
    private let engine = AudioBridgeEngine()
    private var routingGeneration: UInt64 = 0
    private var manuallyStopped = false
    private var iconCache: [URL: NSImage] = [:]
    private let store = SelectionStore()
    private let probeQueue = DispatchQueue(label: "cz.bytelab.audiobridge.discovery", qos: .utility)
    private var observation: CatalogObservation?
    private var pendingRefresh = false
    private var canSave = true
    var canEditSelections: Bool { canSave && !routingRequested && !routingTransitioning }
    var canStartRouting: Bool {
        startUnavailableReason == nil
    }
    var startUnavailableReason: String? {
        if routingRequested || routingTransitioning { return "Stop routing before starting a new route." }
        if !canSave { return "Saved configuration needs attention before routing can start." }
        if let inputIssue { return inputIssue }
        if let outputIssue { return outputIssue }
        if AVAudioApplication.shared.recordPermission != .granted { return "Grant microphone permission before starting." }
        return routeReadiness
    }
    var canStopRouting: Bool { routingRequested || routingTransitioning || routingFault != nil }

    init() {
        let preferences = UserDefaults.standard
        if let saved = preferences.object(forKey: "AudioBridge.bufferFrames") as? NSNumber,
           saved.int64Value > 0, saved.int64Value <= 32768 { customBufferFrames = saved.uint32Value }
        for (key, direction) in [("AudioBridge.inputTrim", AudioDirection.input), ("AudioBridge.outputGain", .output)] {
            if let saved = preferences.object(forKey: key) as? NSNumber,
               saved.doubleValue.isFinite, GainSettings.range.contains(saved.doubleValue) {
                if direction == .input { inputTrim = saved.doubleValue } else { outputGain = saved.doubleValue }
            }
        }
        if let saved = UserDefaults.standard.string(forKey: "AudioBridge.bufferProfile"),
           let profile = BufferProfile(rawValue: saved) { bufferProfile = profile }
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
        if routingFault != nil { return "Action required" }
        if routingTransitioning { return routingRequested ? "Starting" : "Stopping" }
        if routingRequested {
            guard let snapshot = engineSnapshot, snapshot.primed,
                  snapshot.inputCallbacks > 0, snapshot.outputCallbacks > 0,
                  snapshot.outputFrames > 0 else { return "Starting — waiting for callbacks" }
            if snapshot.underrunFrames > 0 || snapshot.overrunFrames > 0
                || snapshot.bufferedFrames == 0 || snapshot.formatFaults > 0 {
                return "Experimental routing — buffer glitches"
            }
            return "Experimental routing active"
        }
        if manuallyStopped { return "Stopped" }
        if error != nil { return "Action required" }
        if selection.input.uid == nil || selection.output.uid == nil { return "Unconfigured" }
        if inputIssue != nil || outputIssue != nil { return "Selection requires attention" }
        return "Devices selected — ready for experimental routing"
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
    func duplicateMonoInput() {
        guard let channels = device(.input)?.input.physicalChannels, channels.count == 1 else { return }
        var next = selection
        next.input.lane1 = channels[0]; next.input.lane2 = channels[0]
        commit(next)
    }
    private func commit(_ next: RouteSelection) {
        guard canEditSelections else { return }
        do { try store.save(next); selection = next; error = nil }
        catch { self.error = "Unable to save selections: \(error). Previous selections retained." }
    }
    func startRouting() {
        guard canStartRouting else { return }
        routingGeneration &+= 1
        let generation = routingGeneration
        routingFault = nil; engineSnapshot = nil; manuallyStopped = false
        routingRequested = true; routingTransitioning = true
        UserDefaults.standard.set(true, forKey: "AudioBridge.desiredRouting")
        engine.start(selection: selection, profile: bufferProfile, bufferFrames: customBufferFrames,
                     inputTrim: inputTrim, outputGain: outputGain, updated: { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.routingGeneration == generation, self.routingRequested else { return }
                self.engineSnapshot = snapshot
                if let fault = snapshot.fault {
                    self.routingRequested = false
                    UserDefaults.standard.set(false, forKey: "AudioBridge.desiredRouting")
                    self.routingFault = fault
                } else if AVAudioApplication.shared.recordPermission != .granted {
                    self.stopRouting()
                    self.routingFault = "Microphone permission is no longer granted. Restore permission before starting again."
                }
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.routingGeneration == generation else { return }
                self.routingTransitioning = false
                if case .failure(let error) = result {
                    self.routingRequested = false
                    UserDefaults.standard.set(false, forKey: "AudioBridge.desiredRouting")
                    self.routingFault = error.localizedDescription
                }
            }
        })
    }
    func stopRouting() {
        // Persist deliberate Stop before acknowledging it; no retry or reconnect can override it.
        UserDefaults.standard.set(false, forKey: "AudioBridge.desiredRouting")
        routingGeneration &+= 1
        let generation = routingGeneration
        routingRequested = false; routingTransitioning = true; manuallyStopped = true
        engineSnapshot = nil; routingFault = nil
        engine.stop { [weak self] result in
            Task { @MainActor in
                guard let self, self.routingGeneration == generation else { return }
                self.routingTransitioning = false
                if case .failure(let error) = result { self.routingFault = error.localizedDescription }
            }
        }
    }
    func setBufferProfile(_ profile: BufferProfile) {
        guard canEditSelections else { return }
        bufferProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "AudioBridge.bufferProfile")
        customBufferFrames = nil
        UserDefaults.standard.removeObject(forKey: "AudioBridge.bufferFrames")
    }
    var bufferMinimum: UInt32 { max(16, max(device(.input)?.bufferFrames ?? 16, device(.output)?.bufferFrames ?? 16)) }
    var bufferMaximum: UInt32 { 32768 }
    var selectedBufferFrames: UInt32 { customBufferFrames ?? bufferProfile.targetFrames(deviceBuffer: min(4096, bufferMinimum)) }
    func setBufferFrames(_ frames: UInt32) {
        guard canEditSelections, frames >= bufferMinimum, frames <= bufferMaximum else { return }
        customBufferFrames = frames
        UserDefaults.standard.set(Int(frames), forKey: "AudioBridge.bufferFrames")
    }
    func setGain(_ decibels: Double, direction: AudioDirection) {
        guard canSave, decibels.isFinite, GainSettings.range.contains(decibels) else { return }
        if direction == .input { inputTrim = decibels } else { outputGain = decibels }
        UserDefaults.standard.set(decibels, forKey: direction == .input ? "AudioBridge.inputTrim" : "AudioBridge.outputGain")
        engine.setGains(inputTrim: inputTrim, outputGain: outputGain)
    }
    var routePlan: Phase2Plan? {
        try? Phase2Plan(selection: selection, devices: catalog.devices, profile: bufferProfile, bufferFrames: customBufferFrames)
    }
    var routeReadiness: String? {
        guard inputIssue == nil, outputIssue == nil else { return nil }
        do { _ = try Phase2Plan(selection: selection, devices: catalog.devices, profile: bufferProfile, bufferFrames: customBufferFrames); return nil }
        catch { return error.localizedDescription }
    }
    func quit() {
        engine.stop { _ in Task { @MainActor in NSApplication.shared.terminate(nil) } }
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
        case .granted: permission = "Granted"
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
