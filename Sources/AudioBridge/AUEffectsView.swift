import AudioBridgeAU
import SwiftUI

struct AUEffectsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        InfoGroupBox("Audio Unit effects", message: effectsHelp) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable effect processing", isOn: Binding(
                    get: { model.effectsProcessingEnabled }, set: { model.setEffectsProcessingEnabled($0) }
                )).disabled(model.routingTransitioning)
                HStack {
                    Menu("Add effect…") {
                        ForEach(model.auCatalog) { listing in Button(listing.name) { model.addAU(listing) } }
                    }.disabled(!model.canEditAU || model.auChain.effects.count >= 8 || model.auCatalog.isEmpty)
                    Button(model.chainBypassed ? "Remove bypass" : "Bypass chain") { model.setChainBypassed(!model.chainBypassed) }
                        .disabled(model.routingTransitioning || !model.effectsProcessingEnabled)
                    Button("Rescan") { model.refreshAudioUnits() }.disabled(model.auCatalogLoading)
                    Spacer()
                    Text(!model.effectsProcessingEnabled ? "Processing off · dry" : (model.chainBypassed ? "Chain bypassed" : "\(model.auChain.active.count) enabled")).font(.caption).foregroundStyle(.secondary)
                }
                if model.auCatalogLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Scanning effects in background… \(model.auScanCount) found").font(.caption)
                    }
                }
                if let error = model.auScanError { Text(error).font(.caption).foregroundStyle(.orange) }
                ForEach(Array(model.auChain.effects.enumerated()), id: \.element.id) { index, effect in
                    HStack {
                        Toggle(isOn: Binding(get: { effect.enabled }, set: { model.setAUEnabled($0, id: effect.id) })) {
                            Text(effect.name).lineLimit(1).help(effect.name)
                        }
                        Spacer()
                        Button("Edit…") { model.editAU(effect) }
                            .disabled(model.routingRequested && !effect.enabled)
                        Button { model.moveAU(id: effect.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("Move earlier in chain")
                        Button { model.moveAU(id: effect.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == model.auChain.effects.count - 1).help("Move later in chain")
                        Button { model.removeAU(id: effect.id) } label: { Image(systemName: "minus.circle") }.help("Remove effect")
                    }.disabled(!model.canEditAU)
                }
                if model.auChain.effects.isEmpty {
                    Text("No effects inserted").foregroundStyle(.secondary)
                }
                if model.auEditorOpen {
                    HStack {
                        Button("Close editor") { model.cancelAUEditor() }
                    }
                }
                if model.auUpdating { Text("Preparing live chain update…").font(.caption) }
            }.padding(4)
        }
    }
    private var effectsHelp: String {
        let catalog = model.auCatalogScannedAt.map { "Cached catalog: \(model.auCatalog.count) effects, scanned \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "The catalog has not been scanned yet."
        return "Physical input mix → input trim → effects in listed order → drift → output gain → physical outputs. Add installed stereo Audio Units, reorder them, or open Edit to adjust their parameters.\n\nTurning Enable effect processing off skips plugin render calls and forwards dry audio. Effects stay loaded and editable; plugin signal meters and DSP state stop advancing. The helper queues and scheduling remain active. The switch is saved and applies at the next processing block; audio already queued can finish first, and audible transitions or retained plugin tails are possible on re-enable. Off does not unload plugins or skip startup loading/validation.\n\nBypass outputs dry audio while effects remain processing, retaining live signal feedback in editors. The bypass preference is preserved while processing is off. Live inserts switch at a processing boundary; audible transitions are possible. A live editor controls the rendering instance; close it to save its settings. Stopped editors save settings for the next Start.\n\n" + catalog + " Rescan after installing or removing effects. Detailed processing counters and latency reports are in Diagnostics."
    }
}
