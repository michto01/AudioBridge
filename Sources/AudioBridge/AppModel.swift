import AudioBridgeStrings
import AppKit
import AudioBridgeCore
import AudioBridgeDiscovery
import AudioBridgeEngine
import AudioBridgeAU
import AVFAudio
import Combine
import Foundation
import Darwin
import UserNotifications

/// Frequent meter/counter updates do not invalidate every settings tab.
@MainActor
final class EngineTelemetry: ObservableObject {
    @Published var snapshot: EngineSnapshot? {
        didSet {
            if snapshot == nil { counterBaseline = nil; countersResetAt = nil }
        }
    }
    @Published private(set) var counterBaseline: EngineSnapshot?
    @Published private(set) var countersResetAt: Date?

    func resetCounters() {
        guard let snapshot else { return }
        counterBaseline = snapshot
        countersResetAt = Date()
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Inspection is opt-in for each launch; never clutter the default interface.
    @Published private(set) var interfaceLanguage = "en"
    @Published var showDebugInformation = false
    @Published private(set) var requiresRearm = false
    @Published private(set) var deviceLossMessage: String?
    @Published private(set) var simpleAudioMode = false
    @Published private(set) var simpleSampleRate: Double = 48000
    @Published private(set) var writableRates: Set<String> = []
    @Published private(set) var simpleBufferFrames: UInt32 = 128
    @Published private(set) var customAUFrames: UInt32?
    @Published private(set) var deviceErrorNotifications = false
    @Published private(set) var notificationStatus = "Not checked"
    @Published var showRemoteTab = true
    @Published var showDiagnosticsTab = true
    @Published private(set) var routingStartedAt: Date?
    @Published private(set) var recovery = RecoveryPolicy()
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var lastRecoveryFault: String?
    @Published private(set) var recoveryHistory: [String] = []
    @Published private(set) var resumeAtLaunch = false
    @Published private(set) var exclusiveAccessEnabled = false
    @Published private(set) var restartRequired = false
    private var retryWork: DispatchWorkItem?
    private var quitting = false
    @Published private(set) var catalog = CatalogSnapshot(devices: [])
    @Published private(set) var selection = RouteSelection()
    @Published private(set) var error: String?
    @Published private(set) var permission = "Not checked"
    @Published private(set) var requestingPermission = false
    @Published private(set) var settingsRestorePending = false
    @Published private(set) var refreshing = false
    @Published private(set) var deviceIcons: [String: NSImage] = [:]
    @Published private(set) var routingRequested = false
    @Published private(set) var routingTransitioning = false
    let telemetry = EngineTelemetry()
    private(set) var engineSnapshot: EngineSnapshot? {
        get { telemetry.snapshot }
        set {
            let previousStatus = status
            let previousActivity = activity
            telemetry.snapshot = newValue
            // Configuration views only need delivery-state transitions. Meters
            // and diagnostics observe telemetry directly at the original cadence.
            if status != previousStatus || activity != previousActivity { objectWillChange.send() }
        }
    }
    @Published private(set) var routingFault: String?
    @Published private(set) var bufferProfile: BufferProfile = .balanced
    @Published private(set) var customBufferFrames: UInt32?
    @Published private(set) var inputTrim: Double = 0
    @Published private(set) var outputGain: Double = 0
    @Published private(set) var outputDeviceVolume: Double?
    @Published private(set) var outputDeviceVolumeWritable = false
    @Published private(set) var outputDeviceVolumeError: String?
    @Published private(set) var outputDeviceVolumeLoading = false
    private var outputVolumeResolvedUID: String?
    var effectiveOutputGain: Double { outputDeviceVolumeWritable ? 0 : outputGain }
    @Published private(set) var auChain = AUChain()
    @Published private(set) var auCatalog: [AUListing] = []
    @Published private(set) var auCatalogLoading = false
    @Published private(set) var auCatalogScannedAt: Date?
    @Published private(set) var auScanCount = 0
    @Published private(set) var auScanError: String?
    let remoteControl = RemoteControlServer()
    private let auScanQueue = DispatchQueue(label: "cz.bytelab.audiobridge.au-scan", qos: .utility)
    @Published private(set) var auEditorOpen = false
    @Published private(set) var auUpdating = false
    @Published private(set) var chainBypassed = false
    @Published private(set) var effectsProcessingEnabled = true
    private var routeUsesAUHost = false
    private var routeAUChainLoaded = false
    private var pendingAU: AULiveCommand?
    private var editAfterUpdate: UUID?
    private var liveEditor = false
    var canEditAU: Bool { canSave && !routingTransitioning && !changingDeviceBuffer && !auEditorOpen && !auUpdating }
    var hasLiveAUHost: Bool { routingRequested && routeUsesAUHost }
    @Published private(set) var writableBuffers: Set<String> = []
    @Published private(set) var changingDeviceBuffer = false
    @Published private(set) var deviceBufferMessage: String?
    @Published private(set) var deviceBufferDrafts: [String: UInt32] = [:]
    private var auEditor: Process?
    private var auEditorDirectory: URL?
    private let engine = AudioBridgeEngine()
    private var routingGeneration: UInt64 = 0
    private var manuallyStopped = false
    private var iconCache: [URL: NSImage] = [:]
    private let store = SelectionStore()
    private let probeQueue = DispatchQueue(label: "cz.bytelab.audiobridge.discovery", qos: .utility)
    private let outputVolumeQueue = DispatchQueue(label: "cz.bytelab.audiobridge.output-volume", qos: .userInitiated)
    private var outputVolumeWorkItem: DispatchWorkItem?
    private var outputVolumeGeneration: UInt64 = 0
    private var observation: CatalogObservation?
    private var pendingRefresh = false
    private var canSave = true
    var canEditSelections: Bool { canSave && !recovery.desired && !routingRequested && !routingTransitioning && !auEditorOpen && !changingDeviceBuffer && !auUpdating }
    var canStartRouting: Bool {
        startUnavailableReason == nil
    }
    var startUnavailableReason: String? {
        if outputDeviceVolumeLoading { return "Checking selected output volume control…" }
        if restartRequired { return "Callback teardown was not confirmed. Restart the app before starting again." }
        if changingDeviceBuffer { return "Applying audio interface buffer size…" }
        if let issue = simpleSettingsIssue { return issue }
        if selectedBufferFrames < bufferMinimum { return "Startup fill must be at least \(bufferMinimum) frames for the current device buffers." }
        if routingRequested || routingTransitioning { return "Stop routing before starting a new route." }
        if !canSave { return "Saved configuration needs attention before routing can start." }
        if let inputIssue { return inputIssue }
        if let outputIssue { return outputIssue }
        if AVAudioApplication.shared.recordPermission != .granted { return "Grant microphone permission before starting." }
        if auEditorOpen { return "Save or close the AU editor before starting." }
        if effectsProcessingEnabled && !auChain.active.isEmpty {
            if auCatalogScannedAt == nil, auCatalogLoading { return "Discovering installed Audio Units…" }
            if auCatalogScannedAt != nil, let missing = auChain.active.first(where: { effect in !auCatalog.contains(where: { $0.id == effect.identity }) }) {
                return "Selected Audio Unit is unavailable: \(missing.name). Remove it or explicitly bypass it."
            }
        }
        return routeReadiness
    }
    var canStopRouting: Bool { recovery.desired || routingRequested || routingTransitioning || (!requiresRearm && routingFault != nil) }
    var stoppedByUser: Bool { manuallyStopped }

    init() {
        let preferences = UserDefaults.standard
        interfaceLanguage = preferences.string(forKey: "AudioBridge.interfaceLanguage") == "cs" ? "cs" : "en"
        // Existing independently configured routes migrate to Expert unchanged.
        simpleAudioMode = preferences.object(forKey: "AudioBridge.simpleAudioMode") as? Bool
            ?? (preferences.data(forKey: "AudioBridge.routeSelection") == nil && preferences.object(forKey: "AudioBridge.bufferFrames") == nil)
        if let saved = preferences.object(forKey: "AudioBridge.simpleSampleRate") as? NSNumber,
           [44100, 48000, 88200, 96000, 192000].contains(saved.doubleValue) { simpleSampleRate = saved.doubleValue }
        if let saved = preferences.object(forKey: "AudioBridge.simpleBufferFrames") as? NSNumber,
           [32, 64, 128, 256, 512, 1024].contains(saved.intValue) { simpleBufferFrames = saved.uint32Value }
        if let saved = preferences.object(forKey: "AudioBridge.auFrames") as? NSNumber,
           [16, 32, 64, 128, 256, 512, 1024].contains(saved.intValue) { customAUFrames = saved.uint32Value }
        requiresRearm = preferences.bool(forKey: "AudioBridge.requiresRearm")
        deviceLossMessage = preferences.string(forKey: "AudioBridge.deviceLossMessage")
        if requiresRearm { routingFault = deviceLossMessage ?? "Device loss stopped routing. Check the route before re-arming." }
        deviceErrorNotifications = preferences.bool(forKey: "AudioBridge.deviceErrorNotifications")
        showRemoteTab = preferences.object(forKey: "AudioBridge.showRemoteTab") as? Bool ?? true
        showDiagnosticsTab = preferences.object(forKey: "AudioBridge.showDiagnosticsTab") as? Bool ?? true
        resumeAtLaunch = preferences.bool(forKey: "AudioBridge.resumeAtLaunch")
        exclusiveAccessEnabled = preferences.bool(forKey: "AudioBridge.exclusiveAccess")
        manuallyStopped = preferences.object(forKey: "AudioBridge.desiredRouting") as? Bool == false
        if let data = preferences.data(forKey: "AudioBridge.auCatalogCache"), data.count <= 8 * 1024 * 1024 {
            do {
                let cache = try JSONDecoder().decode(AUCatalogCache.self, from: data); try cache.validate()
                auCatalog = cache.effects; auCatalogScannedAt = cache.scannedAt
            } catch { auScanError = "Cached effect list could not be read. A background scan will replace it." }
        }
        chainBypassed = preferences.bool(forKey: "AudioBridge.chainBypassed")
        effectsProcessingEnabled = preferences.object(forKey: "AudioBridge.effectsProcessingEnabled") as? Bool ?? true
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
        if !requiresRearm, RecoveryPolicy.shouldResume(autoResume: resumeAtLaunch, desired: preferences.bool(forKey: "AudioBridge.desiredRouting")) { recovery.start() }
        remoteControl.statusProvider = { [weak self] in self?.remoteStatusPayload ?? [:] }
        remoteControl.commandHandler = { [weak self] command in
            guard let self else { return "App model unavailable" }
            return self.performRemoteCommand(command) // nil is a successful command.
        }
        if remoteControl.httpEnabled || remoteControl.oscEnabled { remoteControl.apply() }
        refresh()
        if auCatalogScannedAt == nil { refreshAudioUnits() }
    }
    var inputIssue: String? { selection.issue(in: catalog.devices, direction: .input) }
    var outputIssue: String? { selection.issue(in: catalog.devices, direction: .output) }
    var status: String {
        if routingFault != nil || error != nil { return "Action required" }
        if routingTransitioning { return routingRequested ? "Starting — preparing audio" : "Stopping" }
        if recovery.desired, !routingRequested, let recoveryMessage { return recoveryMessage }
        if routingRequested {
            if let snapshot = engineSnapshot, !snapshot.primed, snapshot.rebufferEvents > 0 {
                return "Rebuffering — waiting for audio"
            }
            guard let snapshot = engineSnapshot, snapshot.primed,
                  snapshot.inputCallbacks > 0, snapshot.outputCallbacks > 0,
                  snapshot.outputFrames > 0 else { return "Starting — filling audio queues" }
            if snapshot.recentGlitches {
                return "Running — delivery warning"
            }
            if !snapshot.inputActive || !snapshot.outputActive { return "Running — waiting for callbacks" }
            return "Running"
        }
        if manuallyStopped { return "Stopped" }
        if error != nil { return "Action required" }
        if selection.input.uid == nil || selection.output.uid == nil { return "Unconfigured" }
        if inputIssue != nil || outputIssue != nil { return "Selection requires attention" }
        if permission != "Granted" { return "Microphone permission required" }
        if routeReadiness != nil { return "Selected format requires attention" }
        return "Devices selected — ready"
    }
    var permissionCanBeRequested: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined && !requestingPermission
    }
    private var remoteStatusPayload: [String: Any] {
        let input = engineSnapshot?.inputLevels ?? []
        let output = engineSnapshot?.outputLevels ?? []
        func level(_ values: [MeterLevel], _ index: Int) -> Double { values.indices.contains(index) ? Double(values[index].amplitude) : 0 }
        return [
            "application": "Audio Bridge",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "status": status,
            "running": routingRequested && engineSnapshot?.primed == true && engineSnapshot?.inputActive == true && engineSnapshot?.outputActive == true,
            "routingRequested": routingRequested,
            "requiresRearm": requiresRearm,
            "input": device(.input)?.name ?? "Unconfigured",
            "output": device(.output)?.name ?? "Unconfigured",
            "inputLeft": level(input, 0), "inputRight": level(input, 1),
            "outputLeft": level(output, 0), "outputRight": level(output, 1),
            "inputTrimDB": inputTrim, "outputGainDB": effectiveOutputGain,
            "outputFallbackGainDB": outputGain,
            "outputLevelControl": outputDeviceVolumeWritable ? "deviceVolume" : "digitalGain",
            "chainBypassed": chainBypassed,
            "effectsProcessingEnabled": effectsProcessingEnabled,
            "effectsProcessingObserved": engineSnapshot?.effectsProcessingEnabled ?? false
        ]
    }
    private func performRemoteCommand(_ command: RemoteCommand) -> String? {
        switch command {
        case .start:
            guard !requiresRearm else { return "Device loss is latched. Check the route and re-arm in the app before remote Start." }
            guard canStartRouting else { return startUnavailableReason ?? "Routing cannot start" }
            startRouting()
        case .stop:
            guard canStopRouting else { return nil }
            stopRouting()
        case .inputGain(let value): setGain(value, direction: .input)
        case .outputGain(let value):
            guard !outputDeviceVolumeLoading else { return "Output volume capability check is pending" }
            guard !outputDeviceVolumeWritable else { return "Device volume is available; digital output gain is fixed at 0 dB" }
            setGain(value, direction: .output)
        case .chainBypass(let value): setChainBypassed(value)
        }
        return nil
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
        if direction == .output { refreshOutputDeviceVolume() }
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
                    Task { @MainActor [weak self] in
                        guard let self, self.routingGeneration == generation, self.routingRequested else { return }
                        if case .failure(let error) = result {
                            self.stopForActionRequired("Routing change failed: \(error.localizedDescription)")
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
    func startRouting(confirmRearm: Bool = false) {
        guard !requiresRearm || confirmRearm, canStartRouting else { return }
        requiresRearm = false; deviceLossMessage = nil
        UserDefaults.standard.set(false, forKey: "AudioBridge.requiresRearm")
        UserDefaults.standard.removeObject(forKey: "AudioBridge.deviceLossMessage")
        retryWork?.cancel(); retryWork = nil
        recovery.start(); recoveryMessage = nil
        beginRoutingAttempt()
    }
    private func beginRoutingAttempt() {
        guard recovery.desired, !quitting else { return }
        recovery.attempting(now: ProcessInfo.processInfo.systemUptime)
        recordRecovery("Preparing explicitly selected route")
        routingGeneration &+= 1
        let generation = routingGeneration
        routingFault = nil; engineSnapshot = nil; manuallyStopped = false
        routeUsesAUHost = true
        routeAUChainLoaded = effectsProcessingEnabled
        routingRequested = true; routingTransitioning = true
        UserDefaults.standard.set(true, forKey: "AudioBridge.desiredRouting")
        engine.start(selection: selection, profile: simpleAudioMode ? .balanced : bufferProfile, bufferFrames: simpleAudioMode ? nil : customBufferFrames,
                     auFrames: simpleAudioMode ? nil : customAUFrames, inputTrim: inputTrim, outputGain: effectiveOutputGain, effects: auChain, chainBypass: chainBypassed,
                     effectsProcessingEnabled: effectsProcessingEnabled,
                     exclusiveAccess: exclusiveAccessEnabled, updated: { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.routingGeneration == generation, self.routingRequested else { return }
                self.engineSnapshot = snapshot
                if let response = snapshot.auResponse, response.id == self.pendingAU?.id {
                    let changedChain = self.pendingAU?.chain != nil
                    self.pendingAU = nil; self.auUpdating = false
                    if changedChain && response.error == nil { self.routeAUChainLoaded = true }
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
                    if response.error == nil { self.applyEffectProcessingToRunningRoute() }
                }
                if let fault = snapshot.fault {
                    self.handleRoutingFailure(fault, kind: snapshot.faultKind ?? .actionRequired)
                } else if AVAudioApplication.shared.recordPermission != .granted {
                    self.stopForActionRequired("Microphone permission is no longer granted. Restore permission before starting again.")
                } else if snapshot.primed && snapshot.inputActive && snapshot.outputActive && !snapshot.recentGlitches {
                    if self.recovery.attempts > 0 && snapshot.glitchCleanSeconds >= 20 {
                        self.recovery.healthy(seconds: snapshot.glitchCleanSeconds)
                    }
                }
            }
        }, completion: { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.routingGeneration == generation else { return }
                self.routingTransitioning = false
                if case .failure(let error) = result {
                    self.handleRoutingFailure(error.localizedDescription, kind: (error as? BridgeFailure)?.kind ?? .actionRequired)
                } else {
                    self.routingStartedAt = Date()
                    self.recordRecovery("HAL started; callback confirmation pending")
                    self.applyEffectProcessingToRunningRoute()
                }
            }
        })
    }
    func stopRouting() {
        recordRecovery("Manual Stop; automatic retries and launch resume suppressed")
        recovery.stop(); recoveryMessage = nil
        retryWork?.cancel(); retryWork = nil
        pendingAU = nil; auUpdating = false; editAfterUpdate = nil
        if liveEditor { liveEditor = false; auEditorOpen = false }
        // Persist deliberate Stop before acknowledging it; no retry or reconnect can override it.
        UserDefaults.standard.set(false, forKey: "AudioBridge.desiredRouting")
        routingGeneration &+= 1
        let generation = routingGeneration
        routingRequested = false; routingTransitioning = true; manuallyStopped = true
        engineSnapshot = nil; routingFault = nil; routingStartedAt = nil
        engine.stop { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.routingGeneration == generation else { return }
                self.routingTransitioning = false
                if case .failure(let error) = result {
                    self.routingFault = error.localizedDescription
                    self.restartRequired = (error as? BridgeFailure)?.kind == .unsafeTeardown
                }
            }
        }
    }
    private func handleRoutingFailure(_ message: String, kind: BridgeFailureKind) {
        recordRecovery("\(kind.rawValue): \(message)")
        routingGeneration &+= 1 // Invalidate late callbacks/completions from this attempt.
        pendingAU = nil; auUpdating = false; liveEditor = false; auEditorOpen = false; editAfterUpdate = nil
        routingRequested = false; routingTransitioning = false; routingStartedAt = nil
        recovery.failed(kind, now: ProcessInfo.processInfo.systemUptime)
        if kind == .deviceLost || kind == .unsafeTeardown {
            requiresRearm = true; deviceLossMessage = message; manuallyStopped = false
            UserDefaults.standard.set(false, forKey: "AudioBridge.desiredRouting")
            UserDefaults.standard.set(true, forKey: "AudioBridge.requiresRearm")
            UserDefaults.standard.set(message, forKey: "AudioBridge.deviceLossMessage")
            notifyDeviceLoss(message)
        }
        lastRecoveryFault = message
        if kind == .recoverable {
            routingFault = nil; recoveryMessage = "Recovering — retry scheduled"
            refresh(); scheduleRetry()
        } else {
            routingFault = message; recoveryMessage = nil
            if kind == .unsafeTeardown { restartRequired = true }
            retryWork?.cancel(); retryWork = nil
            if kind == .deviceLost { refresh() }
        }
    }
    private func recordRecovery(_ message: String) {
        recoveryHistory.append("\(ISO8601DateFormatter().string(from: Date())) · \(message)")
        if recoveryHistory.count > 50 { recoveryHistory.removeFirst(recoveryHistory.count - 50) }
    }
    private func stopForActionRequired(_ message: String) {
        recovery.failed(.actionRequired, now: ProcessInfo.processInfo.systemUptime)
        retryWork?.cancel(); retryWork = nil
        routingGeneration &+= 1
        let generation = routingGeneration
        routingRequested = false; routingTransitioning = true; routingFault = message; routingStartedAt = nil
        engine.stop { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.routingGeneration == generation else { return }
                if case .failure(let error) = result {
                    self.handleRoutingFailure("\(message) \(error.localizedDescription)", kind: .unsafeTeardown)
                } else { self.handleRoutingFailure(message, kind: .actionRequired) }
            }
        }
    }
    private func scheduleRetry() {
        retryWork?.cancel()
        guard recovery.desired, !recovery.blocked, !quitting, let deadline = recovery.retryAt else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recovery.due(now: ProcessInfo.processInfo.systemUptime), !self.routingTransitioning else { return }
            self.attemptRecovery()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }
    private func attemptRecovery() {
        guard recovery.desired, !recovery.blocked, !routingRequested, !routingTransitioning, !quitting else { return }
        if outputDeviceVolumeLoading {
            recoveryMessage = "Waiting for output volume capability check"
            return // The check completion resumes desired routing; no retry storm.
        }
        let now = ProcessInfo.processInfo.systemUptime
        recovery.attempting(now: now)
        let missing = AudioDirection.allCases.filter { direction in
            guard let uid = endpoint(direction).uid else { return false }
            return catalog.devices.first(where: { $0.uid == uid })?.alive != true
        }
        if !missing.isEmpty {
            handleRoutingFailure("Selected device unavailable. Reconnect and check the route before re-arming.", kind: .deviceLost)
            return
        }
        if effectsProcessingEnabled && auCatalogLoading && auCatalogScannedAt == nil && !auChain.active.isEmpty {
            recoveryMessage = "Waiting for effect discovery"
            recovery.failed(.recoverable, now: now); scheduleRetry(); return
        }
        checkPermission()
        if let reason = startUnavailableReason {
            handleRoutingFailure(reason, kind: .actionRequired); return
        }
        recoveryMessage = nil; beginRoutingAttempt()
    }
    func setResumeAtLaunch(_ enabled: Bool) {
        // Enabling this preference never overrides a deliberate Stop.
        resumeAtLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: "AudioBridge.resumeAtLaunch")
    }
    func setVisibleTab(_ tab: String, visible: Bool) {
        if tab == "Remote" { showRemoteTab = visible; UserDefaults.standard.set(visible, forKey: "AudioBridge.showRemoteTab") }
        if tab == "Diagnostics" { showDiagnosticsTab = visible; UserDefaults.standard.set(visible, forKey: "AudioBridge.showDiagnosticsTab") }
    }
    func setExclusiveAccessEnabled(_ enabled: Bool) {
        guard canEditSelections else { return }
        exclusiveAccessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "AudioBridge.exclusiveAccess")
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
    var selectedBufferFrames: UInt32 { (simpleAudioMode ? nil : customBufferFrames) ?? (simpleAudioMode ? BufferProfile.balanced : bufferProfile).targetFrames(deviceBuffer: min(4096, bufferMinimum)) }
    func setBufferFrames(_ frames: UInt32) {
        guard canEditSelections, frames >= bufferMinimum, frames <= bufferMaximum else { return }
        customBufferFrames = frames
        UserDefaults.standard.set(Int(frames), forKey: "AudioBridge.bufferFrames")
    }
    func setGain(_ decibels: Double, direction: AudioDirection) {
        guard canSave, decibels.isFinite, GainSettings.range.contains(decibels) else { return }
        if direction == .output && (outputDeviceVolumeWritable || outputDeviceVolumeLoading) { return }
        if direction == .input { inputTrim = decibels } else { outputGain = decibels }
        UserDefaults.standard.set(decibels, forKey: direction == .input ? "AudioBridge.inputTrim" : "AudioBridge.outputGain")
        engine.setGains(inputTrim: inputTrim, outputGain: effectiveOutputGain)
    }
    func refreshOutputDeviceVolume() {
        outputVolumeGeneration &+= 1
        let generation = outputVolumeGeneration
        guard let uid = selection.output.uid else {
            outputDeviceVolume = nil; outputDeviceVolumeWritable = false; outputDeviceVolumeError = nil
            outputVolumeResolvedUID = nil; outputDeviceVolumeLoading = false
            return
        }
        // Preserve the current mode while rechecking the same endpoint. Clearing
        // writability first would momentarily apply a saved fallback gain live.
        if outputVolumeResolvedUID != uid {
            outputDeviceVolume = nil; outputDeviceVolumeWritable = false
        }
        outputDeviceVolumeError = nil; outputDeviceVolumeLoading = true
        outputVolumeQueue.async { [weak self] in
            let result = Result { try CoreAudioCatalog.outputVolume(uid: uid) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.outputVolumeGeneration == generation, self.selection.output.uid == uid else { return }
                self.outputDeviceVolumeLoading = false; self.outputVolumeResolvedUID = uid
                switch result {
                case .success(let state):
                    self.outputDeviceVolume = state.map { Double($0.scalar) }
                    self.outputDeviceVolumeWritable = state?.writable == true
                case .failure(let error):
                    self.outputDeviceVolume = nil; self.outputDeviceVolumeWritable = false
                    self.outputDeviceVolumeError = error.localizedDescription
                }
                self.engine.setGains(inputTrim: self.inputTrim, outputGain: self.effectiveOutputGain)
                if self.recovery.desired && !self.recovery.blocked && !self.routingRequested && !self.routingTransitioning,
                   self.recovery.retryAt == nil || self.recovery.due(now: ProcessInfo.processInfo.systemUptime) {
                    self.attemptRecovery()
                }
            }
        }
    }
    func setOutputDeviceVolume(_ scalar: Double) {
        guard let uid = selection.output.uid, outputDeviceVolumeWritable, !outputDeviceVolumeLoading,
              scalar.isFinite, (0...1).contains(scalar) else { return }
        outputDeviceVolume = scalar
        outputVolumeGeneration &+= 1
        let generation = outputVolumeGeneration
        outputVolumeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try CoreAudioCatalog.setOutputVolume(uid: uid, scalar: Float(scalar)) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.outputVolumeGeneration == generation, self.selection.output.uid == uid else { return }
                switch result {
                case .success(let actual): self.outputDeviceVolume = Double(actual); self.outputDeviceVolumeError = nil
                case .failure(let error):
                    self.outputDeviceVolumeError = error.localizedDescription
                    self.refreshOutputDeviceVolume()
                }
            }
        }
        outputVolumeWorkItem = work
        outputVolumeQueue.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
    }
    var routePlan: Phase2Plan? {
        try? Phase2Plan(selection: selection, devices: catalog.devices, profile: simpleAudioMode ? .balanced : bufferProfile, bufferFrames: simpleAudioMode ? nil : customBufferFrames, auFrames: simpleAudioMode ? nil : customAUFrames)
    }
    var routeReadiness: String? {
        if let issue = simpleSettingsIssue { return issue }
        guard inputIssue == nil, outputIssue == nil else { return nil }
        do { _ = try Phase2Plan(selection: selection, devices: catalog.devices, profile: simpleAudioMode ? .balanced : bufferProfile, bufferFrames: simpleAudioMode ? nil : customBufferFrames, auFrames: simpleAudioMode ? nil : customAUFrames); return nil }
        catch { return error.localizedDescription }
    }
    func quit() {
        quitting = true; retryWork?.cancel(); retryWork = nil
        routingGeneration &+= 1
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
                        Task { @MainActor [weak self] in self?.auScanCount = count }
                    }
                    usleep(100_000)
                }
                guard process.terminationStatus == 0 else { throw AUError("Effect scan helper failed; cached list retained.") }
                let data = try Data(contentsOf: output)
                guard data.count <= 8 * 1024 * 1024 else { throw AUError("Effect catalog exceeds safety limit.") }
                let cache = try JSONDecoder().decode(AUCatalogCache.self, from: data); try cache.validate(); return cache
            }
            Task { @MainActor [weak self] in
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
            if hasLiveAUHost { sendAU(AULiveCommand(chain: chain)) }
        } catch { self.error = error.localizedDescription }
    }
    func addAU(_ listing: AUListing) {
        guard canEditAU else { return }
        let effect = AUEffect(identity: listing.id, name: listing.name)
        var next = auChain; next.effects.append(effect)
        if hasLiveAUHost { editAfterUpdate = effect.id }
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
        if !routingRequested && recovery.desired { stopRouting() }
        if routingRequested {
            guard hasLiveAUHost else { return }
            if !routeAUChainLoaded {
                editAfterUpdate = effect.id
                sendAU(AULiveCommand(chain: auChain))
                return
            }
            liveEditor = true; auEditorOpen = true
            sendAU(AULiveCommand(edit: effect.id)); return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioBridge-AU-editor-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let input = directory.appendingPathComponent("input.json"), output = directory.appendingPathComponent("saved.json")
            try JSONEncoder().encode(effect).write(to: input, options: .atomic)
            try JSONEncoder().encode(chainBypassed).write(to: directory.appendingPathComponent("bypass.json"), options: .atomic)
            try JSONEncoder().encode(effectsProcessingEnabled).write(to: directory.appendingPathComponent("processing-enabled.json"), options: .atomic)
            let process = Process()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioBridgeAUWorker")
            process.arguments = ["edit", input.path, output.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                Task { @MainActor [weak self] in
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
                Task { @MainActor [weak self] in if case .failure(let error) = result { self?.error = error.localizedDescription } }
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
            Task { @MainActor [weak self] in
                guard let self, self.pendingAU?.id == command.id else { return }
                if case .failure(let error) = result {
                    self.pendingAU = nil; self.auUpdating = false; self.liveEditor = false; self.auEditorOpen = false
                    self.editAfterUpdate = nil; self.error = error.localizedDescription
                    self.stopForActionRequired("Live AU change could not be applied: \(error.localizedDescription)")
                }
            }
        }
    }
    func setEffectsProcessingEnabled(_ enabled: Bool) {
        guard canSave, !quitting else { return }
        effectsProcessingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "AudioBridge.effectsProcessingEnabled")
        if let directory = auEditorDirectory {
            do { try JSONEncoder().encode(enabled).write(to: directory.appendingPathComponent("processing-enabled.json"), options: .atomic) }
            catch { self.error = "Unable to update editor processing indicator: \(error.localizedDescription)" }
        }
        // Preparation completion and the next recovery attempt reconcile the
        // latest preference. A switch never stops/restarts either device.
        applyEffectProcessingToRunningRoute()
    }
    private func applyEffectProcessingToRunningRoute() {
        guard routingRequested, !routingTransitioning, hasLiveAUHost else { return }
        if effectsProcessingEnabled && !routeAUChainLoaded {
            // Keep forwarding dry audio while the saved chain prepares. The
            // matching adoption response enables DSP only if still requested.
            guard pendingAU == nil else { return }
            sendAU(AULiveCommand(chain: auChain))
            return
        }
        let generation = routingGeneration
        engine.auControl(effectsProcessingEnabled: effectsProcessingEnabled) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.routingGeneration == generation, self.routingRequested else { return }
                if case .failure(let error) = result {
                    self.stopForActionRequired("Effect processing switch failed: \(error.localizedDescription)")
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
        if hasLiveAUHost {
            let generation = routingGeneration
            engine.auControl(bypass: bypass) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.routingGeneration == generation, self.routingRequested else { return }
                    if case .failure(let error) = result {
                        self.stopForActionRequired("Chain bypass could not be applied: \(error.localizedDescription)")
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
            let rates = (try? result.get().devices.filter { CoreAudioCatalog.rateIsSettable($0.runtimeID) }.map(\.uid)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var routeDevicesChanged = false
                self.writableBuffers = Set(writable); self.writableRates = Set(rates)
                switch result {
                case .success(let snapshot):
                    routeDevicesChanged = AudioDirection.allCases.contains { direction in
                        guard let uid = self.endpoint(direction).uid else { return false }
                        let old = self.catalog.devices.first { $0.uid == uid }
                        let new = snapshot.devices.first { $0.uid == uid }
                        guard let old, let new else { return (old == nil) != (new == nil) }
                        return old.runtimeID != new.runtimeID || old.alive != new.alive
                            || old.bufferFrames != new.bufferFrames || old.nominalSampleRate != new.nominalSampleRate
                            || !old.facts(for: direction).matchesRoutingTopology(new.facts(for: direction))
                    }
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
                    self.refreshOutputDeviceVolume()
                case .failure(let error):
                    self.catalog = CatalogSnapshot(devices: [], issues: ["Discovery failed: \(error)"])
                }
                self.refreshing = false
                if self.recovery.desired && !self.routingRequested && !self.routingTransitioning && !self.recovery.blocked {
                    if self.recovery.retryAt == nil { self.attemptRecovery() }
                    else if routeDevicesChanged {
                        self.recovery.deviceChanged(now: ProcessInfo.processInfo.systemUptime); self.scheduleRetry()
                    }
                }
                if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
            }
        }
    }
    func setDeviceBuffer(uid: String, frames: UInt32) {
        guard canEditSelections else { return }
        changingDeviceBuffer = true; deviceBufferMessage = nil
        probeQueue.async { [weak self] in
            let result = Result { try CoreAudioCatalog.setBufferFrames(uid: uid, frames: frames) }
            Task { @MainActor [weak self] in
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
    func deviceBufferDraft(uid: String, range: ValueRange?) -> UInt32? {
        if let draft = deviceBufferDrafts[uid] { return draft }
        guard let range, range.minimum.isFinite, range.maximum.isFinite,
              range.minimum >= 1, range.maximum <= Double(UInt32.max), range.maximum >= range.minimum else { return nil }
        let low = UInt32(ceil(range.minimum)), high = UInt32(floor(range.maximum))
        guard low <= high else { return nil }
        let initial = min(high, max(low, catalog.devices.first(where: { $0.uid == uid })?.bufferFrames ?? 64))
        deviceBufferDrafts[uid] = initial
        return initial
    }
    func setDeviceBufferDraft(uid: String, frames: UInt32) {
        guard canEditSelections, let device = catalog.devices.first(where: { $0.uid == uid }),
              writableBuffers.contains(uid), let range = device.bufferFrameRange,
              Double(frames) >= range.minimum, Double(frames) <= range.maximum else { return }
        deviceBufferDrafts[uid] = frames
    }
    func applyDeviceBufferDrafts() {
        guard canEditSelections, !changingDeviceBuffer else { return }
        let rate = simpleAudioMode ? simpleSampleRate : nil
        if simpleAudioMode {
            for direction in AudioDirection.allCases {
                guard let device = device(direction), device.nominalSampleRate == simpleSampleRate
                    || (writableRates.contains(device.uid) && device.availableSampleRates.contains { simpleSampleRate >= $0.minimum && simpleSampleRate <= $0.maximum }) else {
                    deviceBufferMessage = "Both selected devices must support the shared sample rate. Check Audio MIDI Setup or use Expert."; return
                }
                guard device.bufferFrames == simpleBufferFrames
                    || (writableBuffers.contains(device.uid) && device.bufferFrameRange.map { Double(simpleBufferFrames) >= $0.minimum && Double(simpleBufferFrames) <= $0.maximum } == true) else {
                    deviceBufferMessage = "Both selected devices must support the shared buffer request. Use Expert for different buffers."; return
                }
            }
        }
        let pending = AudioDirection.allCases.compactMap { direction -> (String, UInt32)? in
            guard let uid = endpoint(direction).uid, let frames = simpleAudioMode ? simpleBufferFrames : deviceBufferDrafts[uid],
                  (simpleAudioMode || device(direction)?.bufferFrames != frames) else { return nil }
            return (uid, frames)
        }
        let rateRequests = rate.map { value in
            AudioDirection.allCases.compactMap { direction -> (String, Double)? in
                guard let device = device(direction), device.nominalSampleRate != value else { return nil }
                return (device.uid, value)
            }
        } ?? []
        guard !pending.isEmpty || !rateRequests.isEmpty else { deviceBufferMessage = "Interface buffers already match the requested values."; return }
        changingDeviceBuffer = true; deviceBufferMessage = nil
        probeQueue.async { [weak self] in
            var results: [String] = []
            for (uid, rate) in rateRequests {
                do {
                    let actual = try CoreAudioCatalog.setNominalRate(uid: uid, rate: rate)
                    results.append("Sample rate readback: \(actual / 1000) kHz")
                } catch { results.append("Sample rate request failed — \(error.localizedDescription)") }
            }
            results += pending.map { uid, frames -> String in
                do {
                    let current = try CoreAudioCatalog.snapshot(selectedUIDs: [uid]).devices.first { $0.uid == uid }
                    let actual = current?.bufferFrames == frames ? frames : try CoreAudioCatalog.setBufferFrames(uid: uid, frames: frames)
                    return "Requested \(frames), driver reports \(actual) frames"
                } catch { return "Buffer request failed — \(error.localizedDescription)" }
            }
            let message = results.joined(separator: " · ")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changingDeviceBuffer = false
                self.deviceBufferMessage = message
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
        settingsRestorePending = true
        requestingPermission = true
        AVAudioApplication.requestRecordPermission { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestingPermission = false
                self?.checkPermission()
            }
        }
    }
    func openPrivacySettings() {
        settingsRestorePending = true
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
    func openNotificationSettings() {
        settingsRestorePending = true
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
    func consumeSettingsRestoreRequest() -> Bool {
        let pending = settingsRestorePending
        settingsRestorePending = false
        return pending
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        var lines = ["Audio Bridge status", "Version: \(version) / build \(build)", "Time: \(ISO8601DateFormatter().string(from: Date()))"]
        func section(_ title: String, _ rows: [String]) { lines += ["", title] + rows }
        func decimal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

        section("APPLICATION", ["Status: \(status)", "Bundle: \(Bundle.main.bundlePath)", "Microphone permission: \(permission)",
            "Routing requested: \(routingRequested)", "Transitioning: \(routingTransitioning)"])
        if let routingFault { lines.append("Current fault: \(routingFault)") }
        if let error { lines.append("Settings error: \(error)") }
        if let startUnavailableReason, !routingRequested { lines.append("Start unavailable: \(startUnavailableReason)") }

        for direction in AudioDirection.allCases {
            let selected = endpoint(direction), selectedDevice = device(direction)
            let rate = selectedDevice?.nominalSampleRate.map { "\(decimal($0 / 1000)) kHz" } ?? "Unknown"
            section(direction.rawValue.uppercased() + " DEVICE", [
                "Name: \(selectedDevice?.name ?? "Unavailable / unconfigured")",
                "UID: \(selected.uid ?? "None")", "Sample rate: \(rate)",
                "Interface buffer: \(selectedDevice?.bufferFrames.map(String.init) ?? "Unknown") frames"])
        }
        section("ROUTING", selection.inputMix.map { "Input ch\($0.channel) → Mix L: \($0.left), Mix R: \($0.right)" }
            + selection.outputMap.map { "Output ch\($0.channel) ← \($0.source.label)" })
        let deviceVolume = outputDeviceVolume.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable"
        let hogMask = engineSnapshot?.exclusiveAccessMask ?? 0
        section("LEVELS & DEVICE ACCESS", ["Input trim: \(inputTrim) dB", "Output gain applied: \(effectiveOutputGain) dB", "Saved fallback gain: \(outputGain) dB",
            "Output device volume: \(deviceVolume)", "Device volume writable: \(outputDeviceVolumeWritable)",
            "Device volume error: \(outputDeviceVolumeError ?? "None")", "Exclusive access requested: \(exclusiveAccessEnabled)",
            "Exclusive input / output held: \((hogMask & 1) != 0) / \((hogMask & 2) != 0)"])
        section("EFFECTS", ["Effect processing requested: \(effectsProcessingEnabled)",
            "Effect processing observed: \(engineSnapshot?.effectsProcessingEnabled ?? false)",
            "Whole chain bypassed: \(chainBypassed)"] + auChain.effects.enumerated().map {
            "\($0.offset + 1). \($0.element.name) [\($0.element.enabled ? "enabled" : "disabled")]"
        })

        if let s = engineSnapshot {
            if let resetAt = telemetry.countersResetAt {
                let window = DiagnosticCounterWindow(snapshot: s, baseline: telemetry.counterBaseline)
                let fields: [(String, KeyPath<EngineSnapshot, UInt64>)] = [
                    ("Input callbacks", \.inputCallbacks), ("Output callbacks", \.outputCallbacks),
                    ("Captured frames", \.inputFrames), ("Rendered frames", \.outputFrames),
                    ("Underrun frames", \.underrunFrames), ("Overrun frames", \.overrunFrames),
                    ("Format faults", \.formatFaults), ("Rebuffer events", \.rebufferEvents),
                    ("Recentered frames", \.recenterFrames), ("Saturated callbacks", \.driftSaturatedCallbacks),
                    ("Held callbacks", \.driftHeldCallbacks), ("Limited callbacks", \.driftLimitedCallbacks),
                    ("AU processed frames", \.auProcessedFrames), ("AU timed blocks", \.auRenderBlocks),
                    ("AU processing nanoseconds", \.auRenderNanoseconds), ("AU over-budget blocks", \.auRenderOverBudgetBlocks),
                    ("Worker waits", \.auWorkerWaits), ("Late worker wakeups", \.auWorkerLateWakeups),
                    ("Physical output full-scale samples", \.physicalOutputClips)
                ]
                section("MEASUREMENT WINDOW", ["Counters reset at: \(ISO8601DateFormatter().string(from: resetAt))"]
                    + fields.map { "\($0.0): \(window.value($0.1))" }
                    + ["Input full-scale samples L / R: \(window.pairs(s.inputLevels.map(\.clippedSamples), telemetry.counterBaseline?.inputLevels.map(\.clippedSamples)))",
                       "Output full-scale samples L / R: \(window.pairs(s.outputLevels.map(\.clippedSamples), telemetry.counterBaseline?.outputLevels.map(\.clippedSamples)))",
                       "Raw input full-scale samples: \(window.pairs(s.rawInputClips, telemetry.counterBaseline?.rawInputClips))",
                       "Following delivery/AU/signal sections retain lifetime run totals; live state and warnings are unchanged."])
            }
            section("DELIVERY", ["Recent warning: \(s.recentGlitches)", "Warning reason: \(s.deliveryWarningReason ?? "None")",
                "Continuously healthy: \(decimal(s.glitchCleanSeconds)) seconds (warning clears at 5 seconds)",
                "Input callbacks: \(s.inputCallbacks)", "Output callbacks: \(s.outputCallbacks)",
                "Fresh input / output callbacks: \(s.inputActive) / \(s.outputActive)", "Primed: \(s.primed)",
                "Captured frames: \(s.inputFrames)", "Rendered frames: \(s.outputFrames)",
                "Underrun frames: \(s.underrunFrames)", "Overrun frames: \(s.overrunFrames)", "Format faults: \(s.formatFaults)",
                "Counters remain cumulative for this run."])
            section("QUEUES", ["Ready audio queued: \(s.bufferedFrames) frames", "Allocated capacity per queue: \(s.capacity) frames",
                "Reserve target: \(s.targetFrames) frames", "Pending source: \(s.pendingSourceFrames) frames",
                "Capture queue: \(s.captureQueueFrames) frames", "AU in flight: \(s.auInFlightFrames) frames",
                "Processed queue: \(s.processedQueueFrames) frames", "Refill threshold: \(s.refillThresholdFrames) frames",
                "Observed queue min / max: \(s.queueLowFrames.map(String.init) ?? "Unknown") / \(s.queueHighFrames.map(String.init) ?? "Unknown") frames",
                "Rebuffer events: \(s.rebufferEvents)", "Recentered frames: \(s.recenterFrames)"])
            section("CLOCKS", ["Measured input / output difference: \(s.clockEstimateValid ? "\(decimal(Double(s.measuredClockDifferencePPM))) ppm" : "Unavailable")",
                "Commanded correction: \(decimal(Double(s.driftPPM))) ppm", "Applied correction (last callback): \(decimal(Double(s.appliedDriftPPM))) ppm",
                "Saturated callbacks: \(s.driftSaturatedCallbacks)", "Held callbacks: \(s.driftHeldCallbacks)", "Limited callbacks: \(s.driftLimitedCallbacks)"])
            let mean = s.auRenderBlocks > 0 ? "\(decimal(Double(s.auRenderNanoseconds) / Double(s.auRenderBlocks) / 1e6)) ms" : "Unavailable"
            section("AU PROCESSING", ["Processed frames: \(s.auProcessedFrames)", "Effect latency applied: \(decimal(Double(s.auLatencySeconds) * 1000)) ms",
                "Block size: \(s.auBlockFrames) frames", "Timed blocks: \(s.auRenderBlocks)",
                "Block budget: \(decimal(Double(s.auBlockBudgetNanoseconds) / 1e6)) ms",
                "Wall time last: \(decimal(Double(s.auLastRenderNanoseconds) / 1e6)) ms", "Wall time mean: \(mean)",
                "Wall time maximum: \(decimal(Double(s.auMaxRenderNanoseconds) / 1e6)) ms",
                "Render thread Mach scheduling status: \(s.auSchedulingStatus.map(String.init) ?? "No helper") (0 = accepted)",
                "Audio workgroup join status: \(s.auWorkgroupStatus.map(String.init) ?? "No helper"); interval failures: \(s.auWorkgroupIntervalFailures)",
                "Over-budget blocks: \(s.auRenderOverBudgetBlocks)", "Worker signaled waits: \(s.auWorkerWaits)",
                "Late worker wakeups: \(s.auWorkerLateWakeups)", "Maximum signal-to-wake delay: \(decimal(Double(s.auMaxWorkerWakeLatenessNanoseconds) / 1e6)) ms",
                "Wall time includes scheduling and is separate from signal delay."])
            let cycle = s.auWorkerCycle
            section("AU COMPLETE WORKER CYCLE — RUN TOTALS", [
                "Cycles: \(cycle.cycles); over budget: \(cycle.overBudget)",
                "Last / mean / maximum: \(decimal(Double(cycle.lastNanoseconds) / 1e6)) / \(decimal(cycle.cycles > 0 ? Double(cycle.nanoseconds) / Double(cycle.cycles) / 1e6 : 0)) / \(decimal(Double(cycle.maximumNanoseconds) / 1e6)) ms",
                "Chain adoptions: \(cycle.adoptions); maximum: \(decimal(Double(cycle.maximumAdoptionNanoseconds) / 1e6)) ms",
                "Includes adoption, context hooks and autorelease-pool cleanup; excludes idle waits. Not signal latency. Reset counters does not reset these run totals."])
            section("AU PLUGIN TIMING", s.auStages.map { stage in
                let name = auChain.active.first { $0.timingIdentity == stage.identity }?.name ?? "Previous plugin"
                return "Slot \(stage.slot) · \(name): \(stage.blocks) blocks; mean \(decimal(stage.blocks > 0 ? Double(stage.nanoseconds) / Double(stage.blocks) / 1e6 : 0)) ms; max \(decimal(Double(stage.maximumNanoseconds) / 1e6)) ms; over budget \(stage.overBudget)"
            })
            if let event = s.auStarvation, event.sequence > 0 {
                section("LAST AU STARVATION", ["Event: \(event.sequence); lost frames: \(event.lostFrames)",
                    "Capture / ready / in flight: \(event.captureFrames) / \(event.readyFrames) / \(event.inFlightFrames)",
                    "Rendering slot: \(event.renderingStage < 0 ? "Idle / transfer" : String(event.renderingStage + 1))",
                    "Previous block / wake delay: \(decimal(Double(event.lastRenderNanoseconds) / 1e6)) / \(decimal(Double(event.lastWakeNanoseconds) / 1e6)) ms",
                    "Approximate concurrent samples; correlation is not proof of plugin fault."])
            }
            section("SIGNAL", ["Input full-scale samples L / R: \(s.inputLevels.map { String($0.clippedSamples) }.joined(separator: " / "))",
                "Output full-scale samples L / R: \(s.outputLevels.map { String($0.clippedSamples) }.joined(separator: " / "))",
                "Raw input full-scale samples: \(s.rawInputClips.map(String.init).joined(separator: " / "))",
                "Physical output peak (linear): \(s.physicalOutputPeak)", "Physical output full-scale samples: \(s.physicalOutputClips)"])
            if let estimate = delayEstimate {
                let bridge = estimate.subtotalMilliseconds(categories: [.bridge, .callbackBuffer]).map { decimal($0) + " ms" } ?? "Unknown"
                let hardware = estimate.subtotalMilliseconds(categories: [.deviceReported]).map { decimal($0) + " ms" } ?? "Unknown"
                section("DELAY ESTIMATE", ["Snapshot: \(routingRequested ? "Live" : "Last run") · \(s.primed ? "primed" : "starting")",
                    "Bridge + callback buffers: \(bridge)", "Device-reported: \(hardware)",
                    "Known subtotal: \(decimal(estimate.milliseconds(estimate.knownFrames) ?? 0)) ms", "Complete: \(estimate.complete)"])
                for row in estimate.components {
                    lines.append("\(row.label): " + (row.frames.map { "\(decimal(estimate.milliseconds($0) ?? 0)) ms · \(decimal($0)) frames" } ?? "Unknown"))
                }
                lines.append("Estimated allowances; physical end-to-end delay is not measured.")
            }
        } else { section("DELIVERY", ["No engine snapshot available."]) }

        let retrySeconds = recovery.retryAt.map { decimal(max(0, $0 - ProcessInfo.processInfo.systemUptime)) + " seconds" } ?? "No pending retry"
        section("RECOVERY", ["Desired routing: \(recovery.desired)", "Resume at launch: \(resumeAtLaunch)",
            "Blocked: \(recovery.blocked)", "Backoff stage: \(recovery.attempts)", "Retry: \(retrySeconds)",
            "Restart required: \(restartRequired)", "Last recovery fault: \(lastRecoveryFault ?? "None")"])
        lines.append(contentsOf: recoveryHistory.suffix(10).map { "Event: \($0)" })
        lines += ["", "Local diagnostics only; no audio samples or plugin state included."]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
    func setSimpleAudioMode(_ simple: Bool) {
        guard canEditSelections else { return }
        simpleAudioMode = simple
        UserDefaults.standard.set(simple, forKey: "AudioBridge.simpleAudioMode")
    }
    func setSimpleBufferFrames(_ frames: UInt32) {
        guard canEditSelections, [32, 64, 128, 256, 512, 1024].contains(frames) else { return }
        simpleBufferFrames = frames
        UserDefaults.standard.set(frames, forKey: "AudioBridge.simpleBufferFrames")
    }
    func setAUFrames(_ frames: UInt32?) {
        guard canEditSelections, frames == nil || [16, 32, 64, 128, 256, 512, 1024].contains(frames!) else { return }
        customAUFrames = frames
        if let frames { UserDefaults.standard.set(frames, forKey: "AudioBridge.auFrames") }
        else { UserDefaults.standard.removeObject(forKey: "AudioBridge.auFrames") }
    }
    func setDeviceErrorNotifications(_ enabled: Bool) {
        deviceErrorNotifications = enabled
        UserDefaults.standard.set(enabled, forKey: "AudioBridge.deviceErrorNotifications")
        if enabled {
            settingsRestorePending = true
            Task { @MainActor in
                do {
                    _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    refreshNotificationStatus()
                } catch { notificationStatus = error.localizedDescription }
            }
        } else { refreshNotificationStatus() }
    }
    func refreshNotificationStatus() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            // App preference and OS authorization are independent. Switching
            // our notifications off does not revoke macOS authorization.
            switch settings.authorizationStatus {
            case .authorized: notificationStatus = "Allowed"
            case .provisional: notificationStatus = "Allowed quietly"
            case .denied: notificationStatus = "Denied in System Settings"
            case .notDetermined: notificationStatus = "Not requested"
            @unknown default: notificationStatus = "Unknown — check System Settings"
            }
        }
    }
    private func notifyDeviceLoss(_ message: String) {
        guard deviceErrorNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Audio Bridge stopped")
        content.body = L("A selected device disconnected or changed. Check the devices and re-arm in Bridge. Audio will not resume automatically.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "AudioBridge.device-loss", content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor [weak self] in self?.notificationStatus = error.localizedDescription } }
        }
    }

    func setInterfaceLanguage(_ language: String) {
        guard language == "en" || language == "cs" else { return }
        UserDefaults.standard.set(language, forKey: "AudioBridge.interfaceLanguage")
        interfaceLanguage = language
    }

    var simpleRateChoices: [Double] {
        guard let input = device(.input), let output = device(.output) else { return [48000] }
        return [44100, 48000, 88200, 96000, 192000].filter { rate in
            [input, output].allSatisfy { device in
                device.nominalSampleRate == rate || device.availableSampleRates.contains { rate >= $0.minimum && rate <= $0.maximum }
            }
        }
    }
    func setSimpleSampleRate(_ rate: Double) {
        guard canEditSelections, simpleRateChoices.contains(rate) else { return }
        simpleSampleRate = rate
        UserDefaults.standard.set(rate, forKey: "AudioBridge.simpleSampleRate")
    }

    var simpleSettingsIssue: String? {
        guard simpleAudioMode else { return nil }
        guard let input = device(.input), let output = device(.output) else { return "Choose both devices before starting." }
        if input.nominalSampleRate != simpleSampleRate || output.nominalSampleRate != simpleSampleRate {
            return "Apply the shared sample rate before starting. Both drivers must report the requested rate, or use Expert mode."
        }
        if input.bufferFrames != simpleBufferFrames || output.bufferFrames != simpleBufferFrames {
            return "Apply the shared interface buffer request before starting. Both drivers must report the requested value, or use Expert mode."
        }
        return nil
    }

    var simpleBufferChoices: [UInt32] {
        guard let input = device(.input), let output = device(.output) else { return [128] }
        return [32, 64, 128, 256, 512, 1024].filter { frames in
            [input, output].allSatisfy { device in
                device.bufferFrames == frames || (writableBuffers.contains(device.uid)
                    && device.bufferFrameRange.map { Double(frames) >= $0.minimum && Double(frames) <= $0.maximum } == true)
            }
        }
    }

}
