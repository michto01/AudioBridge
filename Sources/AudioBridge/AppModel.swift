import AppKit
import AudioBridgeCore
import AudioBridgeDiscovery
import AudioBridgeEngine
import AudioBridgeAU
import AVFAudio
import Combine
import Foundation
import Darwin

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
    @Published private(set) var auChain = AUChain()
    @Published private(set) var auCatalog: [AUListing] = []
    @Published private(set) var auCatalogLoading = false
    @Published private(set) var auEditorOpen = false
    @Published private(set) var writableBuffers: Set<String> = []
    @Published private(set) var changingDeviceBuffer = false
    @Published private(set) var deviceBufferMessage: String?
    private var auEditor: Process?
    private var auEditorDirectory: URL?
    private let engine = AudioBridgeEngine()
    private var routingGeneration: UInt64 = 0
    private var manuallyStopped = false
    private var iconCache: [URL: NSImage] = [:]
    private let store = SelectionStore()
    private let probeQueue = DispatchQueue(label: "cz.bytelab.audiobridge.discovery", qos: .utility)
    private var observation: CatalogObservation?
    private var pendingRefresh = false
    private var canSave = true
    var canEditSelections: Bool { canSave && !routingRequested && !routingTransitioning && !auEditorOpen && !changingDeviceBuffer }
    var canStartRouting: Bool {
        startUnavailableReason == nil
    }
    var startUnavailableReason: String? {
        if changingDeviceBuffer { return "Applying audio interface buffer size…" }
        if routingRequested || routingTransitioning { return "Stop routing before starting a new route." }
        if !canSave { return "Saved configuration needs attention before routing can start." }
        if let inputIssue { return inputIssue }
        if let outputIssue { return outputIssue }
        if AVAudioApplication.shared.recordPermission != .granted { return "Grant microphone permission before starting." }
        if auEditorOpen { return "Save or close the AU editor before starting." }
        if !auChain.active.isEmpty {
            if auCatalogLoading { return "Discovering installed Audio Units…" }
            if let missing = auChain.active.first(where: { effect in !auCatalog.contains(where: { $0.id == effect.identity }) }) {
                return "Selected Audio Unit is unavailable: \(missing.name). Remove it or explicitly bypass it."
            }
            if selectedBufferFrames < 256 { return "An AU chain needs at least 256 buffer frames." }
        }
        return routeReadiness
    }
    var canStopRouting: Bool { routingRequested || routingTransitioning || routingFault != nil }

    init() {
        let preferences = UserDefaults.standard
        if let saved = preferences.data(forKey: "AudioBridge.auChain") {
            do { auChain = try JSONDecoder().decode(AUChain.self, from: saved); try auChain.validate() }
            catch { self.error = "Saved AU chain could not be read: \(error.localizedDescription). Existing data retained."; canSave = false }
        }
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
        refreshAudioUnits()
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
                     inputTrim: inputTrim, outputGain: outputGain, effects: auChain, updated: { [weak self] snapshot in
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
    var bufferMinimum: UInt32 { max(auChain.active.isEmpty ? 16 : 256, max(device(.input)?.bufferFrames ?? 16, device(.output)?.bufferFrames ?? 16)) }
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
        if let editor = auEditor, editor.isRunning {
            editor.terminate()
            if editor.isRunning { _ = kill(editor.processIdentifier, SIGKILL) }
        }
        engine.stop { _ in Task { @MainActor in NSApplication.shared.terminate(nil) } }
    }
    func refreshAudioUnits() {
        guard !auCatalogLoading else { return }
        auCatalogLoading = true
        probeQueue.async { [weak self] in
            let catalog = AUCatalog.effects()
            Task { @MainActor in self?.auCatalog = catalog; self?.auCatalogLoading = false }
        }
    }
    func updateAUChain(_ chain: AUChain) {
        guard canEditSelections, !auEditorOpen else { return }
        do {
            try chain.validate()
            UserDefaults.standard.set(try JSONEncoder().encode(chain), forKey: "AudioBridge.auChain")
            auChain = chain
        } catch { self.error = error.localizedDescription }
    }
    func addAU(_ listing: AUListing) {
        guard canEditSelections else { return }
        let effect = AUEffect(identity: listing.id, name: listing.name)
        var next = auChain; next.effects.append(effect); updateAUChain(next)
        if auChain.effects.contains(where: { $0.id == effect.id }) { editAU(effect) }
    }
    func setAUEnabled(_ enabled: Bool, id: UUID) {
        var next = auChain
        guard let index = next.effects.firstIndex(where: { $0.id == id }) else { return }
        next.effects[index].enabled = enabled; updateAUChain(next)
    }
    func removeAU(id: UUID) { var next = auChain; next.effects.removeAll { $0.id == id }; updateAUChain(next) }
    func moveAU(id: UUID, offset: Int) {
        var next = auChain
        guard let index = next.effects.firstIndex(where: { $0.id == id }), next.effects.indices.contains(index + offset) else { return }
        next.effects.swapAt(index, index + offset); updateAUChain(next)
    }
    func editAU(_ effect: AUEffect) {
        guard canEditSelections, !auEditorOpen else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioBridge-AU-editor-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let input = directory.appendingPathComponent("input.json"), output = directory.appendingPathComponent("saved.json")
            try JSONEncoder().encode(effect).write(to: input, options: .atomic)
            let process = Process()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioBridgeAUWorker")
            process.arguments = ["edit", input.path, output.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self else { try? FileManager.default.removeItem(at: directory); return }
                    self.auEditorOpen = false; self.auEditor = nil; self.auEditorDirectory = nil
                    defer { try? FileManager.default.removeItem(at: directory) }
                    do {
                        if FileManager.default.fileExists(atPath: output.path) {
                            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                            guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else {
                                throw AUError("AU editor returned oversized state.")
                            }
                            let saved = try JSONDecoder().decode(AUEffect.self, from: Data(contentsOf: output))
                            guard saved.id == effect.id, saved.identity == effect.identity,
                                  let index = self.auChain.effects.firstIndex(where: { $0.id == effect.id }) else { throw AUError("AU editor returned a different effect identity.") }
                            var next = self.auChain; next.effects[index].state = saved.state; self.updateAUChain(next)
                        } else if process.terminationStatus != 0 {
                            self.error = "AU editor exited unexpectedly. Previous plugin settings retained."
                        }
                    } catch { self.error = "Unable to save AU settings: \(error.localizedDescription)" }
                }
            }
            try process.run(); auEditor = process; auEditorDirectory = directory; auEditorOpen = true
        } catch { try? FileManager.default.removeItem(at: directory); self.error = "Unable to open AU editor: \(error.localizedDescription)" }
    }
    func cancelAUEditor() {
        guard let process = auEditor, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
    func refresh() {
        checkPermission()
        guard !refreshing else { pendingRefresh = true; return }
        refreshing = true
        probeQueue.async { [weak self] in
            let result = Result { try CoreAudioCatalog.snapshot() }
            let writable = (try? result.get().devices.filter { CoreAudioCatalog.bufferIsSettable($0.runtimeID) }.map(\.uid)) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.writableBuffers = Set(writable)
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
    func setDeviceBuffer(uid: String, frames: UInt32) {
        guard canEditSelections else { return }
        changingDeviceBuffer = true; deviceBufferMessage = nil
        probeQueue.async { [weak self] in
            let result = Result { try CoreAudioCatalog.setBufferFrames(uid: uid, frames: frames) }
            Task { @MainActor in
                guard let self else { return }
                self.changingDeviceBuffer = false
                switch result {
                case .success(let actual): self.deviceBufferMessage = "Interface buffer: \(actual) frames (requested \(frames))."
                case .failure(let error): self.deviceBufferMessage = "Interface buffer change failed: \(error)"
                }
                self.refresh()
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
