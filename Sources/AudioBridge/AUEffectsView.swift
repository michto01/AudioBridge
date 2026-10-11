import AudioBridgeAU
import SwiftUI

struct AUEffectsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("Audio Unit effects") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Menu("Add effect…") {
                        ForEach(model.auCatalog) { listing in Button(listing.name) { model.addAU(listing) } }
                    }.disabled(!model.canEditAU || model.auChain.effects.count >= 8 || model.auCatalogLoading)
                    Button(model.chainBypassed ? "Enable chain" : "Bypass chain") { model.setChainBypassed(!model.chainBypassed) }
                        .disabled(model.routingTransitioning)
                    Button(model.auCatalogLoading ? "Scanning…" : "Rescan") { model.refreshAudioUnits() }.disabled(model.auCatalogLoading)
                    Spacer()
                    Text(model.chainBypassed ? "Chain bypassed" : "\(model.auChain.active.count) enabled").font(.caption).foregroundStyle(.secondary)
                }
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
                    Text("No effects. Add an installed stereo AU compressor or limiter.").font(.caption).foregroundStyle(.secondary)
                }
                if model.auEditorOpen {
                    HStack {
                        Text(model.routingRequested ? "AU editor open — controls affect routing immediately; close to save." : "AU editor open — save settings before Start.").font(.caption)
                        Button("Close editor") { model.cancelAUEditor() }
                    }
                }
                if model.auUpdating { Text("Preparing live chain update…").font(.caption) }
                if let metrics = model.engineSnapshot, model.routingRequested, !model.auChain.active.isEmpty {
                    Text("AU frames: \(metrics.auProcessedFrames) · reported plugin latency: \((Double(metrics.auLatencySeconds) * 1000).formatted(.number.precision(.fractionLength(1)))) ms")
                        .font(.caption.monospacedDigit())
                }
                Text("Input trim → effects in listed order → output gain. Live inserts prepare alongside the old chain and switch at a block boundary; audible transitions are possible. Bypass chain skips all effects and leaves trim/gain active. Drift/recovery validation remains pending.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
}
