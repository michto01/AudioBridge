import AudioBridgeCore
import AudioBridgeEngine
import SwiftUI

struct SignalMeters: View {
    @ObservedObject var model: AppModel
    let direction: AudioDirection
    var body: some View {
        let snapshot = model.engineSnapshot
        let fresh = model.routingRequested && snapshot?.fault == nil
            && (direction == .input ? snapshot?.inputActive == true : snapshot?.outputActive == true)
        let levels = direction == .input ? snapshot?.inputLevels : snapshot?.outputLevels
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<2, id: \.self) { lane in
                let level = levels?[lane]
                let db = level?.decibels ?? -.infinity
                HStack(spacing: 8) {
                    Text(direction == .input ? "In \(lane + 1)" : (lane == 0 ? "Out L" : "Out R"))
                        .font(.caption).frame(width: 40, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(db >= 0 ? Color.red : (db > -6 ? Color.orange : Color.green))
                                .frame(width: geometry.size.width * (fresh ? min(1, max(0, (db + 60) / 60)) : 0))
                        }
                    }.frame(height: 8)
                    Text(fresh ? (db.isFinite ? String(format: "%.1f dBFS", db) : "−∞ dBFS") : "Inactive")
                        .font(.caption.monospacedDigit()).frame(width: 85, alignment: .trailing)
                    Text((level?.clippedSamples ?? 0) > 0 ? "CLIP" : "")
                        .font(.caption.bold()).foregroundStyle(.red).frame(width: 32)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .help("Latest audio-buffer peaks sampled 20 times per second. CLIP means a sample reached full scale during this run. Inactive means no fresh callback or routing stopped. Local output levels do not confirm sound at the speakers.")
    }
}

struct BufferSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("Buffers") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Bridge buffer", selection: Binding(get: { model.bufferProfile }, set: { model.setBufferProfile($0) })) {
                    ForEach(BufferProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(!model.canEditSelections)
                let target = model.engineSnapshot?.targetFrames ?? model.routePlan?.prefill
                let capacity = model.engineSnapshot?.capacity ?? model.routePlan?.capacity
                let rate = model.engineSnapshot?.sampleRate ?? model.routePlan?.sampleRate
                if let target, let capacity, let rate {
                    Text("Startup fill: \(target) frames (\((Double(target) / rate * 1000).formatted(.number.precision(.fractionLength(1)))) ms) · capacity: \(capacity) frames")
                        .font(.caption)
                    if model.routingRequested, let metrics = model.engineSnapshot {
                        ProgressView(value: Double(metrics.bufferedFrames), total: Double(capacity))
                        Text("Buffered: \(metrics.bufferedFrames) frames · \(metrics.primed ? "Ready" : "Filling")")
                            .font(.caption.monospacedDigit())
                        Text("Underrun: \(metrics.underrunFrames) frames · overrun: \(metrics.overrunFrames) frames")
                            .font(.caption.monospacedDigit())
                    } else { Text("Buffer inactive").font(.caption).foregroundStyle(.secondary) }
                } else { Text("Choose valid devices and channels to see buffer sizes.").font(.caption) }
                Text("Low uses less startup buffering; Robust gives more margin. Device buffers are read-only. These are provisional settings, not measured end-to-end latency. Drift correction is not implemented.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
}
