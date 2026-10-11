import AudioBridgeCore
import SwiftUI

struct MatrixSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("Channel matrix") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Stereo") { model.setMatrix(.identity) }
                    Button("Swap") { model.setMatrix(.swap) }
                    Button("Mono mix") { model.setMatrix(.mono) }
                    Button("Input 1 to both") { model.setMatrix(.inputOne) }
                }
                coefficient("In 1 → Out 1", \.a)
                coefficient("In 2 → Out 1", \.b)
                coefficient("In 1 → Out 2", \.c)
                coefficient("In 2 → Out 2", \.d)
                Text("Linear amplitude 0–1, after AU effects and drift conversion. Changes ramp over 20 ms. Summing full-level lanes can clip; output gain controls headroom.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
    private func coefficient(_ label: String, _ path: WritableKeyPath<ChannelMatrix, Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { model.matrix[keyPath: path] }, set: {
                var next = model.matrix; next[keyPath: path] = $0; model.setMatrix(next)
            }), in: 0...1, step: 0.01)
            Text(model.matrix[keyPath: path].formatted(.number.precision(.fractionLength(2)))).font(.caption.monospacedDigit()).frame(width: 40)
        }
    }
}
