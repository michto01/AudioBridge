import AudioBridgeCore
import SwiftUI

struct DeviceBufferControl: View {
    @ObservedObject var model: AppModel
    let device: DeviceFacts
    @State private var requested = 64
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
                            if $0 != 0 { requested = $0; model.setDeviceBufferDraft(uid: device.uid, frames: UInt32($0)) }
                        })) {
                            ForEach(common, id: \.self) { Text("\($0) frames").tag($0) }
                            Text("Custom…").tag(0)
                        }.labelsHidden()
                        if custom || !common.contains(requested) {
                            TextField("Frames", value: Binding(get: { requested }, set: {
                                requested = $0
                                if let frames = UInt32(exactly: $0) { model.setDeviceBufferDraft(uid: device.uid, frames: frames) }
                            }), format: .number.grouping(.never)).frame(width: 75)
                        }
                    }.disabled(!model.canEditSelections)
                    Text("Current: \(device.bufferFrames.map(String.init) ?? "unknown") frames · requested: \(requested). Apply interface drafts below while stopped; the driver may round or reject.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Interface buffer is read-only or unavailable from this driver.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.deviceBufferMessage { Text(message).font(.caption) }
        }
        .onAppear { readCurrent() }
        .onChange(of: device.bufferFrames) { _, _ in readCurrent() }
    }
    private func readCurrent() {
        let draft = model.deviceBufferDraft(uid: device.uid, range: device.bufferFrameRange)
        if let draft { requested = Int(draft) }
        else { requested = BufferFrameChoices.initialRequest(current: device.bufferFrames, range: device.bufferFrameRange) }
        custom = !BufferFrameChoices.common.contains(requested)
    }
}
