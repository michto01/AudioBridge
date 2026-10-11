import AudioBridgeCore
import SwiftUI

struct MatrixSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Input mix · \(model.device(.input)?.name ?? "Choose an input device")") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Mono → L + R") { model.inputPreset(mono: true) }
                            .disabled(inputChannels.isEmpty)
                        Button("Stereo") { model.inputPreset(mono: false) }
                            .disabled(inputChannels.count < 2)
                        Spacer()
                        Button("Clear") { model.clearPatches(.input) }
                    }
                    headers("Physical input", "Mix L", "Mix R")
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(inputChannels, id: \.self) { channel in
                                let patch = model.selection.inputMix.first { $0.channel == channel } ?? InputPatch(channel: channel)
                                HStack {
                                    Text("Channel \(channel)").frame(maxWidth: .infinity, alignment: .leading)
                                    RoutingCell(title: "Channel \(channel) → Mix L", gain: patch.left) { model.setInputPatch(channel: channel, left: $0, right: patch.right) }
                                    RoutingCell(title: "Channel \(channel) → Mix R", gain: patch.right) { model.setInputPatch(channel: channel, left: patch.left, right: $0) }
                                }
                            }
                        }
                    }.frame(height: gridHeight(inputChannels.count))
                    missing(.input, channels: inputChannels)
                    Text("Click to patch. Right-click a cell for gain. Presets use the first physical channel(s) shown.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }
            Label("Stereo mix → AU effects → drift compensation → output gain", systemImage: "arrow.down")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Output patch · \(model.device(.output)?.name ?? "Choose an output device")") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Stereo") { model.outputStereoPreset() }.disabled(outputChannels.count < 2)
                        Spacer()
                        Button("Clear") { model.clearPatches(.output) }
                    }
                    headers("Physical output", "Out L", "Out R")
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(outputChannels, id: \.self) { channel in
                                let source = model.selection.outputMap.first { $0.channel == channel }?.source ?? .off
                                HStack {
                                    Text("Channel \(channel)").frame(maxWidth: .infinity, alignment: .leading)
                                    outputCell(channel, source: source, side: .left)
                                    outputCell(channel, source: source, side: .right)
                                }.contextMenu {
                                    Button("Explicit mono sum L+R") { model.setOutputPatch(channel: channel, source: .mono) }
                                    Button("Disconnect") { model.setOutputPatch(channel: channel, source: .off) }
                                }
                            }
                        }
                    }.frame(height: gridHeight(outputChannels.count))
                    missing(.output, channels: outputChannels)
                    Text("Patch L or R to multiple outputs. Each output takes one side; right-click a row for an explicit mono sum.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }
            if model.selection.headroomWarning {
                Label("Summing can exceed full scale. Reduce cell gains or trim; no automatic normalization.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.disabled(!model.canEditPatches)
    }
    private var inputChannels: [Int] { model.device(.input)?.input.physicalChannels ?? [] }
    private var outputChannels: [Int] { model.device(.output)?.output.physicalChannels ?? [] }
    private func gridHeight(_ count: Int) -> CGFloat { CGFloat(max(1, min(8, count))) * 32 }
    private func headers(_ physical: String, _ left: String, _ right: String) -> some View {
        HStack { Text(physical).frame(maxWidth: .infinity, alignment: .leading); Text(left).frame(width: 92); Text(right).frame(width: 92) }.font(.caption.bold())
    }
    private func outputCell(_ channel: Int, source: StereoSource, side: StereoSource) -> some View {
        let connected = source == side || source == .mono
        return Button { model.setOutputPatch(channel: channel, source: source == side ? .off : side) } label: {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(connected ? Color.accentColor : Color.secondary).frame(width: 76, height: 24)
        }.buttonStyle(.bordered)
            .accessibilityLabel("Output channel \(channel) from \(side.label)")
            .accessibilityValue(connected ? "Connected" : "Disconnected")
    }
    @ViewBuilder private func missing(_ direction: AudioDirection, channels: [Int]) -> some View {
        let saved = direction == .input ? model.selection.inputMix.map(\.channel) : model.selection.outputMap.map(\.channel)
        ForEach(saved.filter { !channels.contains($0) }, id: \.self) { channel in
            HStack {
                Label("Saved channel \(channel) unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Spacer()
                Button("Remove patch") { model.removeMissingPatch(channel: channel, direction: direction) }
            }.font(.caption)
        }
    }
}

private struct RoutingCell: View {
    let title: String
    let gain: Double
    let set: (Double) -> Void
    @State private var editing = false
    var body: some View {
        Button { set(gain > 0 ? 0 : 1) } label: {
            HStack(spacing: 4) {
                Image(systemName: gain > 0 ? "checkmark.circle.fill" : "circle")
                if gain > 0 { Text(gain.formatted(.number.precision(.fractionLength(2)))).monospacedDigit() }
            }.foregroundStyle(gain > 0 ? Color.accentColor : Color.secondary).frame(width: 76, height: 24)
        }.buttonStyle(.bordered)
            .accessibilityLabel(title).accessibilityValue(gain > 0 ? "Connected, gain \(gain)" : "Disconnected")
            .contextMenu { Button("Adjust gain…") { editing = true } }
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    Slider(value: Binding(get: { gain }, set: set), in: 0...2, step: 0.01)
                    TextField("Linear gain", value: Binding(get: { gain }, set: set), format: .number)
                    Text("1 = unity. Above 1 boosts and can clip. Changes ramp over 20 ms.").font(.caption)
                }.padding().frame(width: 280)
            }
    }
}
