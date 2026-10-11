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
    @Published private(set) var auCatalogScannedAt: Date?
    @Published private(set) var auScanCount = 0
    @Published private(set) var auScanError: String?
    private let auScanQueue = DispatchQueue(label: "cz.bytelab.audiobridge.au-scan", qos: .utility)
    @Published private(set) var auEditorOpen = false
    @Published private(set) var auUpdating = false
    @Published private(set) var chainBypassed = false
    private var pendingAU: AULiveCommand?
    private var editAfterUpdate: UUID?
    private var liveEditor = false
    var canEditAU: Bool { canSave && !routingTransitioning && !changingDeviceBuffer && !auEditorOpen && !auUpdating }
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
    var canEditSelections: Bool { canSave && !routingRequested && !routingTransitioning && !auEditorOpen && !changingDeviceBuffer && !auUpdating }
    var canStartRouting: Bool {
        startUnavailableReason == nil
    }
    var startUnavailableReason: String? {
        if changingDeviceBuffer { return "Applying audio interface buffer size…" }
        if selectedBufferFrames < bufferMinimum { return "Startup fill must be at least \(bufferMinimum) frames for the current device buffers." }
        if routingRequested || routingTransitioning { return "Stop routing before starting a new route." }
        if !canSave { return "Saved configuration needs attention before routing can start." }
        if let inputIssue { return inputIssue }
        if let outputIssue { return outputIssue }
        if AVAudioApplication.shared.recordPermission != .granted { return "Grant microphone permission before starting." }
        if auEditorOpen { return "Save or close the AU editor before starting." }
        if !auChain.active.isEmpty {
            if auCatalogScannedAt == nil, auCatalogLoading { return "Discovering installed Audio Units…" }
            if auCatalogScannedAt != nil, let missing = auChain.active.first(where: { effect in !auCatalog.contains(where: { $0.id == effect.identity }) }) {
                return "Selected Audio Unit is unavailable: \(missing.name). Remove it or explicitly bypass it."
            }
        }
        return routeReadiness
    }
    var canStopRouting: Bool { routingRequested || routingTransitioning || routingFault != nil }
    var stoppedByUser: Bool { manuallyStopped }

    init() {
        let preferences = UserDefaults.standard
        if let data = preferences.data(forKey: "AudioBridge.auCatalogCache"), data.count <= 8 * 1024 * 1024 {
            do {
                let cache = try JSONDecoder().decode(AUCatalogCache.self, from: data); try cache.validate()
                auCatalog = cache.effects; auCatalogScannedAt = cache.scannedAt
            } catch { auScanError = "Cached effect list could not be read. A background scan will replace it." }
        }
        chainBypassed = preferences.bool(forKey: "AudioBridge.chainBypassed")
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
        if auCatalogScannedAt == nil { refreshAudioUnits() }
    }
    var inputIssue: String? { selection.issue(in: catalog.devices, direction: .input) }
    var outputIssue: String? { selection.issue(in: catalog.devices, direction: .output) }
    var status: String {
        if routingFault != nil || error != nil { return "Action required" }
        if routingTransitioning { return routingRequested ? "Starting" : "Stopping" }
        if routingRequested {
            if let snapshot = engineSnapshot, !snapshot.primed, snapshot.rebufferEvents > 0 {
                return "Rebuffering — waiting for audio"
            }
            guard let snapshot = engineSnapshot, snapshot.primed,
                  snapshot.inputCallbacks > 0, snapshot.outputCallbacks > 0,
                  snapshot.outputFrames > 0 else { return "Starting — waiting for callbacks" }
            if RoutingActivity.hasGlitches(underrunFrames: snapshot.underrunFrames,
                overrunFrames: snapshot.overrunFrames, formatFaults: snapshot.formatFaults) || snapshot.bufferedFrames == 0 {
                return "Experimental routing — buffer glitches"
            }
            if !snapshot.inputActive || !snapshot.outputActive { return "Experimental routing — callback gap" }
            return "Experimental routing active"
        }
        if manuallyStopped { return "Stopped" }
        if error != nil { return "Action required" }
        if selection.input.uid == nil || selection.output.uid == nil { return "Unconfigured" }
        if inputIssue != nil || outputIssue != nil { return "Selection requires attention" }
        if permission != "Granted" { return "Microphone permission required" }
        if routeReadiness != nil { return "Selected format requires attention" }
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
        if direction == .input { next.input = endpoint; next.inputMix = [] } else { next.output = endpoint; next.outputMap = [] }
        commit(next)
    }
    var canEditPatches: Bool { canSave && !routingTransitioning && !changingDeviceBuffer }
    func setInputPatch(channel: Int, left: Double, right: Double) {
        guard canEditPatches, InputPatch(channel: channel, left: left, right: right).isValid,
              device(.input)?.input.physicalChannels.contains(channel) == true else { return }
        var next = selection; next.inputMix.removeAll { $0.channel == channel }
        if left > 0 || right > 0 { next.inputMix.append(InputPatch(channel: channel, left: left, right: right)) }
        commitPatches(next)
    }
    func setOutputPatch(channel: Int, source: StereoSource) {
        guard canEditPatches, device(.output)?.output.physicalChannels.contains(channel) == true else { return }
        var next = selection; next.outputMap.removeAll { $0.channel == channel }
        if source != .off { next.outputMap.append(OutputPatch(channel: channel, source: source)) }
        commitPatches(next)
    }
    func inputPreset(mono: Bool) {
        guard canEditPatches, let channels = device(.input)?.input.physicalChannels, let first = channels.first else { return }
        var next = selection
        if mono { next.inputMix = [InputPatch(channel: first, left: 1, right: 1)] }
        else {
            guard channels.count >= 2 else { return }
            next.inputMix = [InputPatch(channel: first, left: 1), InputPatch(channel: channels[1], right: 1)]
        }
        commitPatches(next)
    }
    func outputStereoPreset() {
        guard canEditPatches, let channels = device(.output)?.output.physicalChannels, channels.count >= 2 else { return }
        var next = selection
        next.outputMap = [OutputPatch(channel: channels[0], source: .left), OutputPatch(channel: channels[1], source: .right)]
        commitPatches(next)
    }
    func clearPatches(_ direction: AudioDirection) {
        var next = selection
        if direction == .input { next.inputMix = [] } else { next.outputMap = [] }
        commitPatches(next)
    }
    func removeMissingPatch(channel: Int, direction: AudioDirection) {
        var next = selection
        if direction == .input { next.inputMix.removeAll { $0.channel == channel } }
        else { next.outputMap.removeAll { $0.channel == channel } }
        commitPatches(next)
    }
    private func commitPatches(_ next: RouteSelection) {
        guard canEditPatches, next.patchesValid else { return }
        do {
            try store.save(next); selection = next; error = nil
            if routingRequested {
                let generation = routingGeneration
                engine.setRouting(next) { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.routingGeneration == generation, self.routingRequested else { return }
                        if case .failure(let error) = result {
                            self.stopRouting(); self.routingFault = "Routing change failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
        } catch { self.error = "Unable to save routing: \(error.localizedDescription)" }
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
                     inputTrim: inputTrim, outputGain: outputGain, effects: auChain, chainBypass: chainBypassed, updated: { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.routingGeneration == generation, self.routingRequested else { return }
                self.engineSnapshot = snapshot
                if let response = snapshot.auResponse, response.id == self.pendingAU?.id {
                    self.pendingAU = nil; self.auUpdating = false
                    if self.liveEditor { self.liveEditor = false; self.auEditorOpen = false }
                    if let error = response.error { self.error = "Live AU change failed: \(error)" }
                    if let effect = response.effect, let index = self.auChain.effects.firstIndex(where: { $0.id == effect.id && $0.identity == effect.identity }) {
                        var next = self.auChain; next.effects[index].state = effect.state
                        do {
                            try next.validate(); UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: "AudioBridge.auChain"); self.auChain = next
                        } catch { self.error = "Unable to save live AU settings: \(error.localizedDescription)" }
                    }
                    if response.error == nil, let id = self.editAfterUpdate,
                       let effect = self.auChain.effects.first(where: { $0.id == id }) {
                        self.editAfterUpdate = nil; self.editAU(effect)
                    } else { self.editAfterUpdate = nil }
                }
                if let fault = snapshot.fault {
                    self.pendingAU = nil; self.auUpdating = false; self.liveEditor = false; self.auEditorOpen = false
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
        pendingAU = nil; auUpdating = false; editAfterUpdate = nil
        if liveEditor { liveEditor = false; auEditorOpen = false }
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
        if let editor = auEditor, editor.isRunning {
            editor.terminate()
            if editor.isRunning { _ = kill(editor.processIdentifier, SIGKILL) }
        }
        engine.stop { _ in Task { @MainActor in NSApplication.shared.terminate(nil) } }
    }
    func refreshAudioUnits() {
        guard !auCatalogLoading else { return }
        auCatalogLoading = true; auScanCount = 0; auScanError = nil
        let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioBridgeAUWorker")
        auScanQueue.async { [weak self] in
            let result = Result { () throws -> AUCatalogCache in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioBridge-AU-scan-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let output = directory.appendingPathComponent("catalog.json")
                let process = Process(); process.executableURL = worker; process.arguments = ["scan", output.path]
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run()
                defer { if process.isRunning { process.terminate(); _ = kill(process.processIdentifier, SIGKILL) } }
                let deadline = ProcessInfo.processInfo.systemUptime + 120
                var previousCount = -1
                while process.isRunning {
                    if ProcessInfo.processInfo.systemUptime > deadline { throw AUError("Effect scan timed out; cached list retained.") }
                    if let data = try? Data(contentsOf: directory.appendingPathComponent("progress.json")),
                       let count = try? JSONDecoder().decode(Int.self, from: data), count != previousCount {
                        previousCount = count
                        Task { @MainActor in self?.auScanCount = count }
                    }
                    usleep(100_000)
                }
                guard process.terminationStatus == 0 else { throw AUError("Effect scan helper failed; cached list retained.") }
                let data = try Data(contentsOf: output)
                guard data.count <= 8 * 1024 * 1024 else { throw AUError("Effect catalog exceeds safety limit.") }
                let cache = try JSONDecoder().decode(AUCatalogCache.self, from: data); try cache.validate(); return cache
            }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let cache):
                    self.auCatalog = cache.effects; self.auCatalogScannedAt = cache.scannedAt; self.auScanCount = cache.effects.count
                    if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: "AudioBridge.auCatalogCache") }
                case .failure(let error): self.auScanError = error.localizedDescription
                }
                self.auCatalogLoading = false
            }
        }
    }
    func updateAUChain(_ chain: AUChain) {
        guard canEditAU else { return }
        do {
            try chain.validate()
            UserDefaults.standard.set(try JSONEncoder().encode(chain), forKey: "AudioBridge.auChain")
            auChain = chain
            if routingRequested { sendAU(AULiveCommand(chain: chain)) }
        } catch { self.error = error.localizedDescription }
    }
    func addAU(_ listing: AUListing) {
        guard canEditAU else { return }
        let effect = AUEffect(identity: listing.id, name: listing.name)
        var next = auChain; next.effects.append(effect)
        if routingRequested { editAfterUpdate = effect.id }
        updateAUChain(next)
        if !routingRequested, auChain.effects.contains(where: { $0.id == effect.id }) { editAU(effect) }
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
        guard canEditAU else { return }
        if routingRequested {
            liveEditor = true; auEditorOpen = true
            sendAU(AULiveCommand(edit: effect.id)); return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioBridge-AU-editor-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let input = directory.appendingPathComponent("input.json"), output = directory.appendingPathComponent("saved.json")
            try JSONEncoder().encode(effect).write(to: input, options: .atomic)
            try JSONEncoder().encode(chainBypassed).write(to: directory.appendingPathComponent("bypass.json"), options: .atomic)
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
        if liveEditor {
            engine.auControl(closeEditor: true) { [weak self] result in
                Task { @MainActor in if case .failure(let error) = result { self?.error = error.localizedDescription } }
            }
            return
        }
        guard let process = auEditor, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
    private func sendAU(_ command: AULiveCommand) {
        pendingAU = command; auUpdating = command.edit == nil
        engine.auCommand(command) { [weak self] result in
            Task { @MainActor in
                guard let self, self.pendingAU?.id == command.id else { return }
                if case .failure(let error) = result {
                    self.pendingAU = nil; self.auUpdating = false; self.liveEditor = false; self.auEditorOpen = false
                    self.editAfterUpdate = nil; self.error = error.localizedDescription
                    self.stopRouting(); self.routingFault = "Live AU change could not be applied: \(error.localizedDescription)"
                }
            }
        }
    }
    func setChainBypassed(_ bypass: Bool) {
        guard !routingTransitioning else { return }
        chainBypassed = bypass
        UserDefaults.standard.set(bypass, forKey: "AudioBridge.chainBypassed")
        if let directory = auEditorDirectory {
            do { try JSONEncoder().encode(bypass).write(to: directory.appendingPathComponent("bypass.json"), options: .atomic) }
            catch { self.error = "Unable to update editor bypass indicator: \(error.localizedDescription)" }
        }
        if routingRequested {
            engine.auControl(bypass: bypass) { [weak self] result in
                Task { @MainActor in
                    if case .failure(let error) = result {
                        self?.stopRouting(); self?.routingFault = "Chain bypass could not be applied: \(error.localizedDescription)"
                    }
                }
            }
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
    func copyStatus() {
        var lines = ["Audio Bridge status",
            "Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") / build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")",
            "Time: \(ISO8601DateFormatter().string(from: Date()))",
            "Bundle: \(Bundle.main.bundlePath)", "Status: \(status)", "Microphone permission: \(permission)",
            "Routing requested: \(routingRequested); transitioning: \(routingTransitioning)"]
        if let routingFault { lines.append("Routing fault: \(routingFault)") }
        if let error { lines.append("Settings error: \(error)") }
        if let startUnavailableReason, !routingRequested { lines.append("Start unavailable: \(startUnavailableReason)") }
        for direction in AudioDirection.allCases {
            let selected = endpoint(direction), selectedDevice = device(direction)
            let rate = (selectedDevice?.nominalSampleRate).map { String($0) } ?? "unknown"
            let frames = (selectedDevice?.bufferFrames).map { String($0) } ?? "unknown"
            lines.append("\(direction.rawValue.capitalized): \(selectedDevice?.name ?? "Unavailable/unconfigured") [UID: \(selected.uid ?? "none")] · rate \(rate) Hz · buffer \(frames) frames")
        }
        lines.append("Input matrix: " + selection.inputMix.map { "ch\($0.channel) → L \($0.left), R \($0.right)" }.joined(separator: "; "))
        lines.append("Output map: " + selection.outputMap.map { "ch\($0.channel) ← \($0.source.label)" }.joined(separator: "; "))
        lines.append("Linked input trim: \(inputTrim) dB; output gain: \(outputGain) dB")
        lines.append("AU chain bypassed: \(chainBypassed); effects: " + auChain.effects.map { "\($0.name) [\($0.enabled ? "enabled" : "disabled")]" }.joined(separator: " → "))
        if let s = engineSnapshot {
            lines += ["Input/output callbacks: \(s.inputCallbacks) / \(s.outputCallbacks)",
                "Captured/rendered frames: \(s.inputFrames) / \(s.outputFrames); AU processed: \(s.auProcessedFrames)",
                "Callbacks fresh input/output: \(s.inputActive) / \(s.outputActive); primed: \(s.primed)",
                "Queued/capacity: \(s.bufferedFrames) / \(s.capacity); startup fill: \(s.targetFrames)",
                "Underrun/overrun: \(s.underrunFrames) / \(s.overrunFrames); format faults: \(s.formatFaults)",
                "Drift commanded: \(s.driftPPM) ppm; rebuffers: \(s.rebufferEvents); recentered: \(s.recenterFrames)",
                "AU latency reported: \(s.auLatencySeconds) seconds; physical output peak: \(s.physicalOutputPeak); full-scale samples: \(s.physicalOutputClips)"]
        } else { lines.append("Engine snapshot unavailable (stopped or startup not completed).") }
        if let s = engineSnapshot, let estimate = delayEstimate {
            lines.append("Delay model: \(routingRequested ? "live" : "last run"); \(s.primed ? "primed" : "startup"); estimated allowances, not measured end-to-end")
            for row in estimate.components {
                let value = row.frames.map { "\($0) frames / \(estimate.milliseconds($0) ?? 0) ms" } ?? "unknown"
                lines.append("Delay — \(row.label): \(value)")
            }
            lines.append("Delay known subtotal: \(estimate.milliseconds(estimate.knownFrames) ?? 0) ms; complete: \(estimate.complete)")
            lines.append("Queue + in-flight min/max (primed 20 Hz samples): \(s.queueLowFrames.map(String.init) ?? "unknown") / \(s.queueHighFrames.map(String.init) ?? "unknown") frames")
            lines.append("AU block: \(s.auBlockFrames) frames; timed blocks: \(s.auRenderBlocks); wall last/total/max: \(s.auLastRenderNanoseconds) / \(s.auRenderNanoseconds) / \(s.auMaxRenderNanoseconds) ns (separate from signal delay)")
        }
        lines.append("Local diagnostics only; no audio samples or plugin state included.")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
