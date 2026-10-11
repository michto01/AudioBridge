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
    @State private var expert = false
    var body: some View {
        GroupBox("Bridge buffer") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Slider(value: Binding(get: {
                        log2(Double(max(16, min(model.bufferMaximum, model.selectedBufferFrames))))
                    }, set: {
                        let frames = UInt32(pow(2, $0.rounded()))
                        model.setBufferFrames(max(model.bufferMinimum, min(model.bufferMaximum, frames)))
                    }), in: log2(Double(min(model.bufferMinimum, model.bufferMaximum / 2)))...log2(Double(model.bufferMaximum)))
                        .accessibilityLabel("Bridge startup buffer in frames")
                        .disabled(!model.canEditSelections || model.bufferMinimum > 4096)
                    Text("\(model.selectedBufferFrames) frames").font(.caption.monospacedDigit()).frame(width: 105, alignment: .trailing)
                }
                HStack {
                    Text("\(model.bufferMinimum)–\(model.bufferMaximum) frames").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let rate = model.routePlan?.sampleRate {
                        Text("\((Double(model.selectedBufferFrames) / rate * 1000).formatted(.number.precision(.fractionLength(1)))) ms startup fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Expert", isExpanded: $expert) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Exact frames")
                            TextField("Frames", value: Binding(get: { Int(model.selectedBufferFrames) }, set: {
                                if $0 >= Int(model.bufferMinimum), $0 <= Int(model.bufferMaximum) { model.setBufferFrames(UInt32($0)) }
                            }), format: .number.grouping(.never)).frame(width: 90)
                            Picker("Preset", selection: Binding(get: { model.bufferProfile }, set: { model.setBufferProfile($0) })) {
                                ForEach(BufferProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Button("Apply preset") { model.setBufferProfile(model.bufferProfile) }
                        }.disabled(!model.canEditSelections)
                        Text("Minimum follows the larger device buffer, at least 16 frames. Small values are experimental and can underrun. Interface buffers are changed separately. Stop before changing; no drift correction or measured latency guarantee.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 4)
                }
                if model.routingRequested, let metrics = model.engineSnapshot {
                    Text("\(metrics.bufferedFrames) / \(metrics.capacity) frames · \(metrics.primed ? "Ready" : "Filling") · underrun \(metrics.underrunFrames) · overrun \(metrics.overrunFrames)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
    }
}

struct GainControl: View {
    @ObservedObject var model: AppModel
    let direction: AudioDirection
    private var binding: Binding<Double> {
        Binding(get: { direction == .input ? model.inputTrim : model.outputGain },
                set: { model.setGain($0, direction: direction) })
    }
    var body: some View {
        HStack {
            Text(direction == .input ? "Input trim" : "Output gain").font(.caption).frame(width: 80, alignment: .leading)
            Slider(value: binding, in: GainSettings.range, step: 0.5)
                .accessibilityLabel(direction == .input ? "Input trim in decibels" : "Output gain in decibels")
            TextField("dB", value: binding, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder).frame(width: 65)
                .accessibilityLabel("Exact gain in decibels")
            Text("dB").font(.caption)
            Button { model.setGain(0, direction: direction) } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Reset to 0 dB")
        }
        .help("Digital gain, −60 to +12 dB. Both lanes change together with a 20 ms ramp. Input gain cannot undo clipping already present at capture. Device volume is unchanged.")
    }
}
