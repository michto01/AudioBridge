import AudioBridgeCore
import AudioBridgeEngine
import SwiftUI
import Combine
import AppKit

struct InfoButton: View {
    let title: String
    let message: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            .buttonStyle(.plain).accessibilityLabel(title)
            .popover(isPresented: $showing, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.headline)
                        Text(message).font(.body).fontWeight(.regular).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.frame(width: 380, height: popoverHeight)
            }
    }
    private var popoverHeight: CGFloat {
        let text = NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let bounds = text.boundingRect(with: NSSize(width: 352, height: CGFloat.greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(480, max(120, ceil(bounds.height) + 64))
    }
}

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
                    Text(fresh ? (db.isFinite ? String(format: "%.0f dB", db) : "−∞ dB") : "Inactive")
                        .font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
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
        InfoGroupBox("Bridge FIFO reserve", message: "This is Audio Bridge's software queue, separate from each device's hardware buffer. The default target is twice the larger selected device buffer, with a 64-frame minimum (64-frame devices target 128 frames). It is saved immediately and takes effect on the next Start.\n\nRefill waits for this reserve plus one output callback and FIR lookahead. Smaller reserves reduce queue delay but leave less time for Audio Units and scheduler delays. If delivery losses increase, stop and raise the reserve. The driver buffers remain separate. Expert presets and exact values are available below; the valid minimum follows the larger device buffer, at least 16 frames. Actual delay is shown in Bridge.") {
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
                    }.padding(.top, 4)
                }
                if model.showDebugInformation, model.routingRequested, let metrics = model.engineSnapshot {
                    Divider()
                    ReadoutRow("FIFO", "\(metrics.bufferedFrames) / \(metrics.capacity) frames").font(.caption)
                    ReadoutRow("Correction command", "\(metrics.driftPPM.formatted(.number.precision(.fractionLength(1)))) ppm").font(.caption)
                    ReadoutRow("Underrun / overrun frames", "\(metrics.underrunFrames) / \(metrics.overrunFrames)").font(.caption)
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
            Slider(value: binding, in: GainSettings.range)
                .accessibilityLabel(direction == .input ? "Input trim in decibels" : "Output gain in decibels")
            GainEntry(value: binding, range: GainSettings.range)
                .frame(width: 65)
                .accessibilityLabel("Exact gain in decibels")
            Text("dB").font(.caption).foregroundStyle(.secondary)
            Button { model.setGain(0, direction: direction) } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Reset to 0 dB")
        }
        .help("Digital gain, −60 to +12 dB. Both stereo channels change together with a 20 ms ramp. Input gain cannot undo clipping already present at capture. Device volume is unchanged.")
    }
}

struct OutputDeviceVolumeControl: View {
    @ObservedObject var model: AppModel
    private var volume: Binding<Double> {
        Binding(get: { model.outputDeviceVolume ?? 1 }, set: { model.setOutputDeviceVolume($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Device volume").font(.caption).frame(width: 80, alignment: .leading)
                Slider(value: volume, in: 0...1)
                    .disabled(!model.outputDeviceVolumeWritable)
                    .accessibilityLabel("Selected output device volume")
                Text(model.outputDeviceVolume.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.caption.monospacedDigit()).frame(width: 42, alignment: .trailing)
            }
            if !model.outputDeviceVolumeWritable {
                HStack {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    InfoButton(title: "Device volume", message: model.outputDeviceVolumeError ?? "This output does not expose a writable master volume control. Digital output gain remains separate.")
                }
            }
        }
        .help("Controls the selected device's Core Audio master output volume. This is separate from Audio Bridge digital output gain and may also affect other system audio clients. The device may round the requested value to its supported steps.")
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
    private func refresh() { draft = value.formatted(.number.grouping(.never).precision(.fractionLength(0))) }
    private func commit() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if let parsed = formatter.number(from: draft)?.doubleValue, parsed.isFinite, range.contains(parsed) { value = parsed }
        refresh()
    }
}
