import AppKit
import AVFAudio
import AudioBridgeAUViews
import AudioBridgeAU
import AudioToolbox
import CoreAudioKit
import SwiftUI

@MainActor
final class Editor: NSObject, NSWindowDelegate {
    private static var retained: Editor?
    private var effect: AUEffect
    private let output: URL
    private var unit: AUAudioUnit?
    private var wrapper: AVAudioUnit?
    private var window: NSWindow?
    private var loadTimer: Timer?
    init(effect: AUEffect, output: URL) { self.effect = effect; self.output = output }
    static func launch(input: URL, output: URL) {
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let effect = try JSONDecoder().decode(AUEffect.self, from: Data(contentsOf: input))
            let editor = Editor(effect: effect, output: output); retained = editor; editor.open()
        } catch { exit(2) }
    }
    private func open() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.window = window; window.delegate = self; window.title = "\(effect.name) — AU editor"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Loading effect…").padding())
        window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        loadTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showError("AU editor timed out while loading. Close this window and inspect the plugin installation.") }
        }
        Task { [self] in
            do {
                let wrapper: AVAudioUnit = try await withCheckedThrowingContinuation { continuation in
                    AVAudioUnit.instantiate(with: effect.identity.description, options: []) { unit, error in
                        if let unit { continuation.resume(returning: unit) }
                        else { continuation.resume(throwing: error ?? AUError("Unable to load effect editor.")) }
                    }
                }
                self.wrapper = wrapper
                let unit = wrapper.auAudioUnit; try restore(effect, unit: unit)
                self.unit = unit; loadTimer?.invalidate(); loadTimer = nil
                let legacy = ABCreateCocoaEditor(wrapper.audioUnit, NSSize(width: 660, height: 440))
                window.contentView = NSHostingView(rootView: EffectEditor(unit: unit, legacy: legacy, save: { [weak self] in self?.save() }))
                window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            } catch { loadTimer?.invalidate(); showError(error.localizedDescription) }
        }
    }
    private func showError(_ message: String) { window?.contentView = NSHostingView(rootView: Text(message).padding()) }
    private func save() {
        do {
            if let state = unit?.fullState {
                effect.state = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
                guard effect.state!.count <= 8 * 1024 * 1024 else { throw AUError("Plugin state exceeds the 8 MB limit.") }
            }
            try JSONEncoder().encode(effect).write(to: output, options: .atomic)
            NSApplication.shared.terminate(nil)
        } catch { showError(error.localizedDescription) }
    }
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}

@MainActor
private struct EffectEditor: View {
    let unit: AUAudioUnit
    let legacy: NSView?
    let save: () -> Void
    @State private var native: NSViewController?
    @State private var requested = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(unit.audioUnitName ?? "Audio Unit").font(.headline)
                Spacer()
                Button("Save settings") { save() }
                Button("Cancel") { NSApplication.shared.terminate(nil) }
            }
            Text("Changes apply on the next Start; this editor does not audition audio.").font(.caption).foregroundStyle(.secondary)
            if let legacy {
                ScrollView([.horizontal, .vertical]) {
                    LegacyEditor(view: legacy).frame(width: max(400, legacy.frame.width), height: max(300, legacy.frame.height))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if let native { NativeEditor(controller: native).frame(minWidth: 400, minHeight: 300).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
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
            unit.requestViewController { controller in Task { @MainActor in native = controller } }
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
            Text(parameter.string(fromValue: nil)).font(.caption).frame(width: 100, alignment: .trailing)
        }
        .onAppear { value = parameter.value }
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in value = parameter.value }
    }
}
