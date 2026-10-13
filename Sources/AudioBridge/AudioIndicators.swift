import AudioBridgeStrings
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
            .buttonStyle(.plain).focusEffectDisabled().accessibilityLabel(title)
            .popover(isPresented: $showing, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LT(title)).font(.headline)
                        Text(LT(message)).font(.body).fontWeight(.regular).fixedSize(horizontal: false, vertical: true)
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
    @ObservedObject private var telemetry: EngineTelemetry
    let direction: AudioDirection
    let compact: Bool
    @State private var clipUntil = [Date.distantPast, Date.distantPast]
    @State private var displayedDB = [-60.0, -60.0]
    init(model: AppModel, direction: AudioDirection, compact: Bool = false) {
        self.model = model
        self.direction = direction
        self.compact = compact
        telemetry = model.telemetry
    }
    var body: some View {
        let snapshot = telemetry.snapshot
        let fresh = model.routingRequested && snapshot?.fault == nil
            && (direction == .input ? snapshot?.inputActive == true : snapshot?.outputActive == true)
        let levels = direction == .input ? snapshot?.inputLevels : snapshot?.outputLevels
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<2, id: \.self) { lane in
                let level = levels?[lane]
                let db = level?.decibels ?? -.infinity
                let clipped = fresh && ((level?.amplitude ?? 0) >= 1 || clipUntil[lane] > Date())
                HStack(spacing: 8) {
                    Text(L("Mix \(lane == 0 ? "L" : "R")"))
                        .font(.caption).frame(width: 44, alignment: .leading)
                    MeterBar(fraction: fresh ? min(1, max(0, (displayedDB[lane] + 60) / 60)) : 0)
                        .frame(height: 8)
                        .overlay(alignment: .trailing) {
                            if compact && clipped {
                                Text("CLIP").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.red).padding(.horizontal, 2)
                                    .background(.background)
                            }
                        }
                    Text(fresh ? (db.isFinite ? String(format: L("%.0f dB"), db) : L("−∞ dB")) : LT("Inactive"))
                        .font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
                    if !compact {
                        Text(clipped ? "CLIP" : "")
                            .font(.caption.bold()).foregroundStyle(.red).frame(width: 32)
                    }
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
                displayedDB[lane] = reading.isFinite ? min(0, max(-60, reading.rounded())) : -60
            }
        }
        .onChange(of: fresh) { _, active in
            if !active {
                displayedDB = [-60, -60]
            }
        }
        .help(L("Audio-buffer peaks sampled approximately five times per second for display. Health transitions appear immediately. CLIP holds for one second after full-scale samples: signal level, not a routing glitch. Cumulative counts remain in Diagnostics. Inactive means no fresh callback or routing stopped. Local output levels do not confirm sound at the speakers."))
    }
}

/// Core Animation interpolates a layer mask without requesting SwiftUI body,
/// Canvas draws or layout at display refresh rate. Values still arrive at 5 Hz.
private struct MeterBar: NSViewRepresentable {
    let fraction: Double
    func makeNSView(context: Context) -> NativeMeterBar { NativeMeterBar() }
    func updateNSView(_ view: NativeMeterBar, context: Context) { view.setFraction(fraction) }
}

private final class NativeMeterBar: NSView {
    private let gradient = CAGradientLayer()
    private let fillMask = CALayer()
    private var fraction: CGFloat = 0
    private var laidOutBounds: NSRect?
    private var appearanceDirty = true
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = [NSColor.systemGreen.cgColor, NSColor.systemGreen.cgColor,
            NSColor.systemYellow.cgColor, NSColor.systemYellow.cgColor,
            NSColor.systemRed.cgColor, NSColor.systemRed.cgColor]
        gradient.locations = [0, 0.90, 0.90, 0.98, 0.98, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 0.5)
        fillMask.backgroundColor = NSColor.white.cgColor
        fillMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        gradient.mask = fillMask; layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError(L("init(coder:) has not been implemented")) }
    convenience init() { self.init(frame: .zero) }
    override func layout() {
        super.layout()
        // Scrolling can request layout without resizing a meter. Do not
        // rebuild its layer geometry or interrupt its ongoing animation.
        guard laidOutBounds != bounds || appearanceDirty else { return }
        laidOutBounds = bounds
        appearanceDirty = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = bounds.height / 2
        gradient.frame = bounds
        fillMask.cornerRadius = bounds.height / 2
        fillMask.position = CGPoint(x: 0, y: bounds.height / 2)
        fillMask.bounds = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); appearanceDirty = true; needsLayout = true
    }
    func setFraction(_ value: Double) {
        let next = CGFloat(min(1, max(0, value)))
        guard next != fraction else { return }
        let oldWidth = fillMask.presentation()?.bounds.width ?? fillMask.bounds.width
        let duration = next > fraction ? 0.12 : 0.3
        fraction = next
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fillMask.bounds.size.width = bounds.width * next
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = oldWidth; animation.toValue = bounds.width * next
        animation.duration = duration; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fillMask.add(animation, forKey: "meter")
    }
}

struct BufferSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var telemetry: EngineTelemetry
    @State private var expert = false
    @State private var custom = false
    init(model: AppModel) {
        self.model = model
        telemetry = model.telemetry
    }
    var body: some View {
        InfoGroupBox(L("Bridge FIFO reserve"), message: L("This is Audio Bridge's software queue, separate from each device's hardware buffer. The default target is twice the larger selected device buffer, with a 64-frame minimum (64-frame devices target 128 frames). It is saved immediately and takes effect on the next Start.\n\nRefill waits for this reserve plus one output callback and FIR lookahead. Smaller reserves reduce queue delay but leave less time for Audio Units and scheduler delays. If delivery losses increase, stop and raise the reserve. The driver buffers remain separate. Expert presets and exact values are available below; the valid minimum follows the larger device buffer, at least 16 frames. Actual delay is shown in Bridge.")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    let common = BufferFrameChoices.common.filter { $0 >= Int(model.bufferMinimum) && $0 <= Int(model.bufferMaximum) }
                    Picker(L("Queue reserve"), selection: Binding(get: {
                        custom || !common.contains(Int(model.selectedBufferFrames)) ? 0 : Int(model.selectedBufferFrames)
                    }, set: {
                        custom = $0 == 0
                        if $0 != 0 { model.setBufferFrames(UInt32($0)) }
                    })) {
                        ForEach(common, id: \.self) { Text(L("\($0) frames")).tag($0) }
                        Text(L("Custom…")).tag(0)
                    }.disabled(!model.canEditSelections)
                    if custom || !common.contains(Int(model.selectedBufferFrames)) {
                        TextField(L("Frames"), value: Binding(get: { Int(model.selectedBufferFrames) }, set: {
                            if $0 >= Int(model.bufferMinimum), $0 <= Int(model.bufferMaximum) { model.setBufferFrames(UInt32($0)) }
                        }), format: .number.grouping(.never)).frame(width: 90).disabled(!model.canEditSelections)
                    }
                    if model.showDebugInformation {
                        Text(L("\(model.selectedBufferFrames) frames")).font(.caption.monospacedDigit()).frame(width: 105, alignment: .trailing)
                    }
                }
                if model.showDebugInformation {
                HStack {
                    Text(L("\(model.bufferMinimum)–\(model.bufferMaximum) frames")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let rate = model.routePlan?.sampleRate {
                        Text(L("\((Double(model.selectedBufferFrames) / rate * 1000).formatted(.number.precision(.fractionLength(1)))) ms queue reserve"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                }
                DisclosureGroup(L("Expert"), isExpanded: $expert) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("Exact frames"))
                            TextField(L("Frames"), value: Binding(get: { Int(model.selectedBufferFrames) }, set: {
                                if $0 >= Int(model.bufferMinimum), $0 <= Int(model.bufferMaximum) { model.setBufferFrames(UInt32($0)) }
                            }), format: .number.grouping(.never)).frame(width: 90)
                            Picker(L("Preset"), selection: Binding(get: { model.bufferProfile }, set: { model.setBufferProfile($0) })) {
                                ForEach(BufferProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Button(L("Apply preset")) { model.setBufferProfile(model.bufferProfile) }
                        }.disabled(!model.canEditSelections)
                    }.padding(.top, 4)
                }
                if model.showDebugInformation, model.routingRequested, let metrics = telemetry.snapshot {
                    Divider()
                    ReadoutRow(L("Ready audio / allocated capacity"), L("\(metrics.bufferedFrames) / \(metrics.capacity) frames")).font(.caption)
                    ReadoutRow(L("Correction command"), L("\(metrics.driftPPM.formatted(.number.precision(.fractionLength(1)))) ppm")).font(.caption)
                    ReadoutRow(L("Underrun / overrun frames"), L("\(metrics.underrunFrames) / \(metrics.overrunFrames)")).font(.caption)
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
            Text(LT(direction == .input ? L("Input trim") : L("Output gain"))).font(.caption).frame(width: 80, alignment: .leading)
            Slider(value: binding, in: GainSettings.range)
                .accessibilityLabel(direction == .input ? L("Input trim in decibels") : L("Output gain in decibels"))
            GainEntry(value: binding, range: GainSettings.range)
                .frame(width: 65)
                .accessibilityLabel(L("Exact gain in decibels"))
            Text(L("dB")).font(.caption).foregroundStyle(.secondary)
            Button { model.setGain(0, direction: direction) } label: { Image(systemName: "arrow.uturn.backward") }
                .help(L("Reset to 0 dB"))
        }
        .help(L("Digital gain, −60 to +12 dB. Both stereo channels change together with a 20 ms ramp. Input gain cannot undo clipping already present at capture. Device volume is unchanged."))
    }
}

struct OutputDeviceVolumeControl: View {
    @ObservedObject var model: AppModel
    var allowsDigitalFallback = true
    var compactLabel = false
    private var volume: Binding<Double> {
        Binding(get: { model.outputDeviceVolume ?? 1 }, set: { model.setOutputDeviceVolume($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.outputDeviceVolumeLoading {
                HStack {
                    Text(L("Output level")).font(.caption).frame(width: 80, alignment: .leading)
                    ProgressView().controlSize(.small)
                    Text(L("Checking…")).font(.caption).foregroundStyle(.secondary)
                }
            } else if model.outputDeviceVolumeWritable {
                HStack(spacing: 8) {
                    Text(LT(compactLabel ? "Volume" : "Device volume"))
                        .font(.caption).fixedSize(horizontal: true, vertical: false)
                    Slider(value: volume, in: 0...1)
                        .accessibilityLabel(L("Selected output device volume"))
                    Text(model.outputDeviceVolume.map { L("\(Int(($0 * 100).rounded()))%") } ?? "—")
                        .font(.caption.monospacedDigit()).frame(width: 42, alignment: .trailing)
                }
            } else {
                if allowsDigitalFallback { GainControl(model: model, direction: .output) }
                HStack {
                    Text(allowsDigitalFallback ? L("Digital fallback") : L("Device volume unavailable")).font(.caption).foregroundStyle(.secondary)
                    InfoButton(title: L("Output level"), message: (model.outputDeviceVolumeError ?? L("This output does not expose a writable master volume control.")) + L("\n\nDigital output gain is the fallback in the Bridge tab. It changes the stereo signal smoothly before physical output mapping. When writable device volume is available, digital gain is fixed at 0 dB; the saved fallback setting is retained for devices without volume control."))
                }
            }
        }
        .help(L("Uses selected-device volume when writable, otherwise digital gain in Bridge. Device volume may affect other audio clients and may be rounded by the driver."))
    }
}

/// Keep incomplete edits (notably a leading minus) away from the live model.
struct GainEntry: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(L("Gain"), text: $draft)
            .textFieldStyle(.roundedBorder).focused($focused)
            .onAppear { refresh() }
            .onChange(of: value) { _, _ in if !focused { refresh() } }
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onSubmit { commit(); focused = false }
            .help(L("Enter a value, then press Return or leave the field to apply."))
    }
    private func refresh() { draft = value.formatted(.number.grouping(.never).precision(.fractionLength(0))) }
    private func commit() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if let parsed = formatter.number(from: draft)?.doubleValue, parsed.isFinite, range.contains(parsed) { value = parsed }
        refresh()
    }
}
