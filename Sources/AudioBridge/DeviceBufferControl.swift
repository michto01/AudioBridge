import AudioBridgeCore
import SwiftUI

struct DeviceBufferControl: View {
    @ObservedObject var model: AppModel
    let device: DeviceFacts
    @State private var requested = 512
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.writableBuffers.contains(device.uid), let range = device.bufferFrameRange,
               range.minimum.isFinite, range.maximum.isFinite,
               range.minimum >= 1, range.maximum <= Double(UInt32.max), range.maximum >= range.minimum {
                let lower = Int(ceil(range.minimum)), upper = Int(floor(range.maximum))
                if upper >= lower {
                    HStack {
                        Text("Interface buffer")
                        if upper > lower {
                            Slider(value: Binding(get: { Double(min(upper, max(lower, requested))) }, set: { requested = Int($0) }),
                                   in: Double(lower)...Double(upper), step: 1)
                        }
                        TextField("Frames", value: $requested, format: .number.grouping(.never)).frame(width: 75)
                        Button("Apply") { model.setDeviceBuffer(uid: device.uid, frames: UInt32(requested)) }
                            .disabled(requested < lower || requested > upper)
                    }.disabled(!model.canEditSelections)
                    Text("\(lower)–\(upper) frames · device-wide; may affect other audio apps. Stop routing to apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Interface buffer is read-only or unavailable from this driver.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.deviceBufferMessage { Text(message).font(.caption) }
        }
        .onAppear { requested = Int(device.bufferFrames ?? 512) }
        .onChange(of: device.bufferFrames) { _, frames in requested = Int(frames ?? 512) }
    }
}
