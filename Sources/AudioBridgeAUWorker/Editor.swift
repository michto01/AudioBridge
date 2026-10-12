import AppKit
import AVFAudio
import AudioBridgeAUViews
import AudioBridgeAU
import AudioToolbox
import CoreAudioKit
import SwiftUI

@MainActor
final class EditorBypassStatus: ObservableObject {
    @Published var bypassed = false
    @Published var effectsProcessingEnabled = true
}

@MainActor
final class Editor: NSObject, NSWindowDelegate {
    private static var retained: Editor?
    private var effect: AUEffect
    private let output: URL
    private var unit: AUAudioUnit?
    private var wrapper: AVAudioUnit?
    private var window: NSWindow?
    private var loadTimer: Timer?
    private var liveCompletion: ((AUEffect?, String?) -> Void)?
    private var sizeObservation: NSObjectProtocol?
    private var lastEditorSize = NSSize.zero
    private let bypassStatus = EditorBypassStatus()
    private var statusTimer: Timer?
    init(effect: AUEffect, output: URL) { self.effect = effect; self.output = output }
    static func launch(input: URL, output: URL) {
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let effect = try JSONDecoder().decode(AUEffect.self, from: Data(contentsOf: input))
            let editor = Editor(effect: effect, output: output); retained = editor; editor.open()
            editor.statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak editor] _ in
                MainActor.assumeIsolated {
                    if let data = try? Data(contentsOf: input.deletingLastPathComponent().appendingPathComponent("bypass.json")),
                       let value = try? JSONDecoder().decode(Bool.self, from: data) { editor?.bypassStatus.bypassed = value }
                    if let data = try? Data(contentsOf: input.deletingLastPathComponent().appendingPathComponent("processing-enabled.json")),
                       let value = try? JSONDecoder().decode(Bool.self, from: data) { editor?.bypassStatus.effectsProcessingEnabled = value }
                }
            }
        } catch { exit(2) }
    }
    static func showLive(effect: AUEffect, wrapper: AVAudioUnit, bypassed: Bool, effectsProcessingEnabled: Bool = true, completion: @escaping (AUEffect?, String?) -> Void) {
        NSApplication.shared.setActivationPolicy(.regular)
        let editor = Editor(effect: effect, output: URL(fileURLWithPath: "/dev/null"))
        editor.wrapper = wrapper; editor.unit = wrapper.auAudioUnit; editor.liveCompletion = completion
        editor.bypassStatus.bypassed = bypassed
        editor.bypassStatus.effectsProcessingEnabled = effectsProcessingEnabled
        retained = editor; editor.open()
    }
    static func closeLive() { if retained?.liveCompletion != nil { retained?.save() } }
    static func setChainBypassed(_ bypassed: Bool) {
        guard let retained, retained.bypassStatus.bypassed != bypassed else { return }
        retained.bypassStatus.bypassed = bypassed
    }
    static func setEffectsProcessingEnabled(_ enabled: Bool) {
        guard let retained, retained.bypassStatus.effectsProcessingEnabled != enabled else { return }
        retained.bypassStatus.effectsProcessingEnabled = enabled
    }
    private func open() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.window = window; window.delegate = self; window.title = "\(effect.name) — AU editor"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Loading effect…").padding())
        window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        if let wrapper { install(wrapper); return }
        loadTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showError("AU editor timed out while loading. Close this window and inspect the plugin installation.") }
        }
        Task { [self] in
            do {
                let wrapper = try await instantiateWrapper(effect)
                self.wrapper = wrapper
                let unit = wrapper.auAudioUnit; try restore(effect, unit: unit)
                self.unit = unit; loadTimer?.invalidate(); loadTimer = nil
                install(wrapper)
            } catch { loadTimer?.invalidate(); showError(error.localizedDescription) }
        }
    }
    private func install(_ wrapper: AVAudioUnit) {
        let legacy = ABCreateCocoaEditor(wrapper.audioUnit, .zero)
        window?.contentView = NSHostingView(rootView: EffectEditor(unit: wrapper.auAudioUnit, legacy: legacy,
            live: liveCompletion != nil, bypassStatus: bypassStatus, fit: { [weak self] in self?.fit($0) }, save: { [weak self] in self?.save() }))
        if let legacy {
            fit(legacy)
            DispatchQueue.main.async { [weak self, weak legacy] in if let legacy { self?.fit(legacy) } }
            legacy.postsFrameChangedNotifications = true
            sizeObservation = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                object: legacy, queue: .main) { [weak self, weak legacy] _ in
                MainActor.assumeIsolated { if let legacy { self?.fit(legacy) } }
            }
        }
        window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private func fit(_ view: NSView) {
        let fitting = view.fittingSize
        let size = NSSize(width: max(view.frame.width, fitting.width), height: max(view.frame.height, fitting.height))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size != lastEditorSize, let window else { return }
        lastEditorSize = size
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setContentSize(NSSize(width: min(max(440, size.width + 32), screen.width - 40),
            height: min(max(350, size.height + 140), screen.height - 80)))
    }
    private func showError(_ message: String) { window?.contentView = NSHostingView(rootView: Text(message).padding()) }
    private func save() {
        do {
            if let state = unit?.fullState {
                effect.state = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
                guard effect.state!.count <= 8 * 1024 * 1024 else { throw AUError("Plugin state exceeds the 8 MB limit.") }
            }
            if let liveCompletion {
                self.liveCompletion = nil
                statusTimer?.invalidate()
                if let sizeObservation { NotificationCenter.default.removeObserver(sizeObservation); self.sizeObservation = nil }
                window?.delegate = nil; window?.close()
                liveCompletion(effect, nil); Self.retained = nil
            } else {
                try JSONEncoder().encode(effect).write(to: output, options: .atomic)
                NSApplication.shared.terminate(nil)
            }
        } catch { showError(error.localizedDescription) }
    }
    func windowWillClose(_ notification: Notification) {
        if liveCompletion != nil { save() } else { NSApplication.shared.terminate(nil) }
    }
}

@MainActor
private struct EffectEditor: View {
    let unit: AUAudioUnit
    let legacy: NSView?
    let live: Bool
    @ObservedObject var bypassStatus: EditorBypassStatus
    let fit: (NSView) -> Void
    let save: () -> Void
    @State private var native: NSViewController?
    @State private var requested = false
    @State private var nativeResolved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(unit.audioUnitName ?? "Audio Unit").font(.headline)
                Spacer()
                Button(live ? "Close and save" : "Save settings") { save() }
                if !live { Button("Cancel") { NSApplication.shared.terminate(nil) } }
            }
            Text(live ? "Controls affect the running effect immediately. Close saves settings." : "Changes apply on the next Start.").font(.caption).foregroundStyle(.secondary)
            if !bypassStatus.effectsProcessingEnabled {
                Label("Effect processing off — dry audio; plugin signal meters are paused.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if bypassStatus.bypassed {
                Label("Chain bypassed — you can edit settings; output uses dry audio.", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let legacy {
                ScrollView([.horizontal, .vertical]) {
                    LegacyEditor(view: legacy).frame(width: max(400, legacy.frame.width), height: max(300, legacy.frame.height))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if let native { NativeEditor(controller: native).frame(minWidth: 400, minHeight: 300).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !nativeResolved {
                ProgressView("Loading native editor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let presets = unit.factoryPresets, !presets.isEmpty {
                            Menu("Factory presets") {
                                ForEach(presets, id: \.number) { preset in
                                    Button(preset.name) { unit.currentPreset = preset }
                                }
                            }
                        }
                        ForEach(unit.parameterTree?.allParameters ?? [], id: \.address) { parameter in
                            ParameterControl(parameter: parameter)
                        }
                        if unit.parameterTree?.allParameters.isEmpty != false {
                            Text("No generic parameters exposed. The plugin may require its own editor.")
                        }
                    }.padding(4)
                }
            }
        }.padding()
        .onAppear {
            guard !requested, legacy == nil else { return }; requested = true
            unit.requestViewController { controller in
                Task { @MainActor in
                    native = controller
                    nativeResolved = true
                    if let controller {
                        let preferred = controller.preferredContentSize
                        if preferred.width > 0, preferred.height > 0,
                           preferred.width.isFinite, preferred.height.isFinite { controller.view.setFrameSize(preferred) }
                        fit(controller.view)
                    }
                }
            }
        }
    }
}
private struct LegacyEditor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
private struct NativeEditor: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}
@MainActor
private struct ParameterControl: View {
    let parameter: AUParameter
    @State private var value: Float = 0
    var body: some View {
        HStack {
            Text(parameter.displayName).frame(width: 200, alignment: .leading)
            if parameter.minValue.isFinite, parameter.maxValue.isFinite, parameter.maxValue > parameter.minValue {
                Slider(value: Binding(get: { Double(value) }, set: {
                    value = Float($0); parameter.value = value
                }), in: Double(parameter.minValue)...Double(parameter.maxValue))
                    .disabled(!parameter.flags.contains(.flag_IsWritable))
            }
            // Some AUv2 formatters crash on a null value pointer (observed TDR Nova).
            // Numeric host formatting also avoids running plugin formatting during SwiftUI layout.
            Text(value.formatted(.number.precision(.fractionLength(3))))
                .font(.caption.monospacedDigit()).frame(width: 100, alignment: .trailing)
        }
        .onAppear { value = parameter.value }
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in value = parameter.value }
    }
}
