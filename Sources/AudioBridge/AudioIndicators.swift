import AudioBridgeCore
import AudioBridgeEngine
import SwiftUI

struct SignalMeters: View {
    @ObservedObject var model: AppModel
    let direction: AudioDirection
    @State private var clipUntil = [Date.distantPast, Date.distantPast]
    @State private var displayedDB = [-60.0, -60.0]
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
                    Text("Mix \(lane == 0 ? "L" : "R")")
                        .font(.caption).frame(width: 44, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            GeometryReader { bar in
                                HStack(spacing: 0) {
                                    Color.green.frame(width: bar.size.width * 0.90)
                                    Color.yellow.frame(width: bar.size.width * 0.08)
                                    Color.red.frame(maxWidth: .infinity)
                                }
                            }
                            .mask(alignment: .leading) {
                                Capsule().frame(width: geometry.size.width * (fresh ? min(1, max(0, (displayedDB[lane] + 60) / 60)) : 0))
                            }
                        }
                    }.frame(height: 8)
                    Text(fresh ? (db.isFinite ? String(format: "%.1f dBFS", db) : "−∞ dBFS") : "Inactive")
                        .font(.caption.monospacedDigit()).frame(width: 85, alignment: .trailing)
                    Text(fresh && ((level?.amplitude ?? 0) >= 1 || clipUntil[lane] > Date()) ? "CLIP" : "")
                        .font(.caption.bold()).foregroundStyle(.red).frame(width: 32)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: levels?.map(\.clippedSamples)) { old, new in
            for lane in 0..<2 where (new?[lane] ?? 0) > (old?[lane] ?? 0) {
                clipUntil[lane] = Date().addingTimeInterval(1)
            }
        }
        .onChange(of: levels?.map(\.decibels)) { _, new in
            for lane in 0..<2 {
                let reading = new.flatMap { $0.indices.contains(lane) ? $0[lane] : nil } ?? -.infinity
                let target = reading.isFinite ? min(0, max(-60, reading)) : -60
                let rising = target > displayedDB[lane]
                withAnimation(.easeOut(duration: rising ? 0.045 : 0.24)) {
                    displayedDB[lane] = target
                }
            }
        }
        .onChange(of: fresh) { _, active in
            if !active {
                withAnimation(.easeOut(duration: 0.18)) { displayedDB = [-60, -60] }
            }
        }
        .help("Latest audio-buffer peaks sampled 20 times per second. CLIP holds for one second after full-scale samples: signal level, not a routing glitch. Cumulative counts remain in Diagnostics. Inactive means no fresh callback or routing stopped. Local output levels do not confirm sound at the speakers.")
    }
}

struct BufferSettings: View {
    @ObservedObject var model: AppModel
    @State private var expert = false
    @State private var custom = false
    var body: some View {
        GroupBox("Bridge buffer") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    let common = BufferFrameChoices.common.filter { $0 >= Int(model.bufferMinimum) && $0 <= Int(model.bufferMaximum) }
                    Picker("Queue reserve", selection: Binding(get: {
                        custom || !common.contains(Int(model.selectedBufferFrames)) ? 0 : Int(model.selectedBufferFrames)
                    }, set: {
                        custom = $0 == 0
                        if $0 != 0 { model.setBufferFrames(UInt32($0)) }
                    })) {
                        ForEach(common, id: \.self) { Text("\($0) frames").tag($0) }
                        Text("Custom…").tag(0)
                    }.disabled(!model.canEditSelections)
                    if custom || !common.contains(Int(model.selectedBufferFrames)) {
                        TextField("Frames", value: Binding(get: { Int(model.selectedBufferFrames) }, set: {
                            if $0 >= Int(model.bufferMinimum), $0 <= Int(model.bufferMaximum) { model.setBufferFrames(UInt32($0)) }
                        }), format: .number.grouping(.never)).frame(width: 90).disabled(!model.canEditSelections)
                    }
                    if model.showDebugInformation {
                        Text("\(model.selectedBufferFrames) frames").font(.caption.monospacedDigit()).frame(width: 105, alignment: .trailing)
                    }
                }
                if model.showDebugInformation {
                HStack {
                    Text("\(model.bufferMinimum)–\(model.bufferMaximum) frames").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let rate = model.routePlan?.sampleRate {
                        Text("\((Double(model.selectedBufferFrames) / rate * 1000).formatted(.number.precision(.fractionLength(1)))) ms queue reserve")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Refill waits for this reserve plus one output callback and required FIR lookahead. Actual queue delay is shown in Playback.")
                    .font(.caption).foregroundStyle(.secondary)
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
                        Text("Minimum follows the larger device buffer, at least 16 frames. FIR conversion adds 17 frames of lookahead. Small targets can underrun; stop before changing. No measured latency guarantee.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 4)
                }
                if model.selectedBufferFrames < 256 {
                    Label("Small bridge fill leaves little AU scheduling margin. If glitches increase, stop and try 256 or 512 frames here; device buffers are separate.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.showDebugInformation, model.routingRequested, let metrics = model.engineSnapshot {
                    Text("Drift command: \(metrics.driftPPM.formatted(.number.precision(.fractionLength(1)))) ppm · rebuffers \(metrics.rebufferEvents) · recentered \(metrics.recenterFrames) frames")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
            GainEntry(value: binding, range: GainSettings.range)
                .frame(width: 65)
                .accessibilityLabel("Exact gain in decibels")
            Text("dB").font(.caption)
            Button { model.setGain(0, direction: direction) } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Reset to 0 dB")
        }
        .help("Digital gain, −60 to +12 dB. Both stereo channels change together with a 20 ms ramp. Input gain cannot undo clipping already present at capture. Device volume is unchanged.")
    }
}

/// Keep incomplete edits (notably a leading minus) away from the live model.
struct GainEntry: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Gain", text: $draft)
            .textFieldStyle(.roundedBorder).focused($focused)
            .onAppear { refresh() }
            .onChange(of: value) { _, _ in if !focused { refresh() } }
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onSubmit { commit(); focused = false }
            .help("Enter a value, then press Return or leave the field to apply.")
    }
    private func refresh() { draft = value.formatted(.number.grouping(.never).precision(.fractionLength(2))) }
    private func commit() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if let parsed = formatter.number(from: draft)?.doubleValue, parsed.isFinite, range.contains(parsed) { value = parsed }
        refresh()
    }
}
