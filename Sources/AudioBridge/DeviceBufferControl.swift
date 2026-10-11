import AudioBridgeCore
import SwiftUI

struct DeviceBufferControl: View {
    @ObservedObject var model: AppModel
    let device: DeviceFacts
    @State private var requested = 512
    @State private var custom = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.writableBuffers.contains(device.uid), let range = device.bufferFrameRange,
               range.minimum.isFinite, range.maximum.isFinite,
               range.minimum >= 1, range.maximum <= Double(UInt32.max), range.maximum >= range.minimum {
                let lower = Int(ceil(range.minimum)), upper = Int(floor(range.maximum))
                if upper >= lower {
                    HStack {
                        Text("Interface buffer")
                        let common = BufferFrameChoices.common.filter { $0 >= lower && $0 <= upper }
                        Picker("Size", selection: Binding(get: { custom || !common.contains(requested) ? 0 : requested }, set: {
                            custom = $0 == 0
                            if $0 != 0 { requested = $0 }
                        })) {
                            ForEach(common, id: \.self) { Text("\($0) frames").tag($0) }
                            Text("Custom…").tag(0)
                        }.labelsHidden()
                        if custom || !common.contains(requested) {
                            TextField("Frames", value: $requested, format: .number.grouping(.never)).frame(width: 75)
                        }
                        Button("Apply") { model.setDeviceBuffer(uid: device.uid, frames: UInt32(requested)) }
                            .disabled(requested < lower || requested > upper)
                    }.disabled(!model.canEditSelections)
                    Text("\(lower)–\(upper) frames · common sizes are suggestions; driver may round or reject. Stop to apply; affects other apps using this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Interface buffer is read-only or unavailable from this driver.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.deviceBufferMessage { Text(message).font(.caption) }
        }
        .onAppear { requested = Int(device.bufferFrames ?? 512) }
        .onChange(of: device.bufferFrames) { _, frames in requested = Int(frames ?? 512); custom = !BufferFrameChoices.common.contains(requested) }
    }
}
