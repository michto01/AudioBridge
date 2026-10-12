import AudioBridgeStrings
import AudioBridgeAU
import SwiftUI

struct AUEffectsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        InfoGroupBox(L("Audio Unit effects"), message: effectsHelp) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("Enable effect processing"), isOn: Binding(
                    get: { model.effectsProcessingEnabled }, set: { model.setEffectsProcessingEnabled($0) }
                ))
                HStack {
                    Menu(L("Add effect…")) {
                        ForEach(model.auCatalog) { listing in Button(listing.name) { model.addAU(listing) } }
                    }.disabled(!model.canEditAU || model.auChain.effects.count >= 8 || model.auCatalog.isEmpty)
                    Button(LT(model.chainBypassed ? L("Remove bypass") : L("Bypass chain"))) { model.setChainBypassed(!model.chainBypassed) }
                        .disabled(model.routingTransitioning || !model.effectsProcessingEnabled)
                    Button(L("Rescan")) { model.refreshAudioUnits() }.disabled(model.auCatalogLoading)
                    Spacer()
                    Text(!model.effectsProcessingEnabled ? L("Processing off · dry") : (model.chainBypassed ? L("Chain bypassed") : L("\(model.auChain.active.count) enabled"))).font(.caption).foregroundStyle(.secondary)
                }
                if model.auCatalogLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L("Scanning effects in background… \(model.auScanCount) found")).font(.caption)
                    }
                }
                if let error = model.auScanError { Text(error).font(.caption).foregroundStyle(.orange) }
                ForEach(Array(model.auChain.effects.enumerated()), id: \.element.id) { index, effect in
                    HStack {
                        Toggle(isOn: Binding(get: { effect.enabled }, set: { model.setAUEnabled($0, id: effect.id) })) {
                            Text(effect.name).lineLimit(1).help(effect.name)
                        }
                        Spacer()
                        Button(L("Edit…")) { model.editAU(effect) }
                            .disabled(model.routingRequested && (!effect.enabled || !model.hasLiveAUHost))
                        Button { model.moveAU(id: effect.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help(L("Move earlier in chain"))
                        Button { model.moveAU(id: effect.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == model.auChain.effects.count - 1).help(L("Move later in chain"))
                        Button { model.removeAU(id: effect.id) } label: { Image(systemName: "minus.circle") }.help(L("Remove effect"))
                    }.disabled(!model.canEditAU)
                }
                if model.auChain.effects.isEmpty {
                    Text(L("No effects inserted")).foregroundStyle(.secondary)
                }
                if model.auEditorOpen {
                    HStack {
                        Button(L("Close editor")) { model.cancelAUEditor() }
                    }
                }
                if model.auUpdating { Text(L("Preparing live chain update…")).font(.caption) }
            }.padding(4)
        }
    }
    private var effectsHelp: String {
        let catalog = model.auCatalogScannedAt.map { L("Cached catalog: \(model.auCatalog.count) effects, scanned \($0.formatted(date: .abbreviated, time: .shortened)).") } ?? L("The catalog has not been scanned yet.")
        return L("Physical input mix → input trim → effects in listed order → drift → output gain → physical outputs. Add installed stereo Audio Units, reorder them, or open Edit to adjust their parameters.\n\nTurning Enable effect processing off fades to dry audio over 20 ms, then stops plugin render calls. Loaded effects remain editable; their signal meters and DSP state pause once the fade finishes. The helper and queues stay active in both modes. Starting with processing off loads no plugins; enabling prepares the saved chain while dry audio continues, then fades it in without restarting either device. The switch is saved; changes during preparation are reconciled when startup finishes. Manual Stop still stops the bridge. Queued audio finishes normally. A fade reduces abrupt level changes but does not align the dry signal with plugin latency, erase plugin tails or guarantee inaudible transitions for every effect.\n\nBypass fades to dry audio while effects remain processing, retaining live signal feedback in editors. The bypass preference is preserved while processing is off. Live inserts switch at a processing boundary; audible transitions are possible. A live editor controls the rendering instance; close it to save its settings. Stopped editors save settings for the next Start.\n\n") + catalog + L(" Rescan after installing or removing effects. Detailed processing counters and latency reports are in Diagnostics.")
    }
}
