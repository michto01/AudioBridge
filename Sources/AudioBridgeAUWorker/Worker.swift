import AppKit
import AudioBridgeAU
import AudioBridgeRealtime
import AudioToolbox
import AVFAudio
import CoreAudioKit
import Foundation

@MainActor
func instantiateWrapper(_ effect: AUEffect) async throws -> AVAudioUnit {
    var description = effect.identity.description
    guard let component = AudioComponentFindNext(nil, &description),
          AudioComponentGetDescription(component, &description) == noErr else {
        throw AUError("Unable to find \(effect.name).")
    }
    // Some legacy plugins initialize UI timers/message infrastructure during
    // processor creation. Use AppKit's thread for synchronous AUv2 creation.
    if description.componentFlags & AudioComponentFlags.requiresAsyncInstantiation.rawValue == 0 {
        return AVAudioUnitEffect(audioComponentDescription: description)
    }
    return try await withCheckedThrowingContinuation { continuation in
        AVAudioUnit.instantiate(with: description, options: []) { unit, error in
            if let unit { continuation.resume(returning: unit) }
            else { continuation.resume(throwing: error ?? AUError("Unable to load \(effect.name).")) }
        }
    }
}

func restore(_ effect: AUEffect, unit: AUAudioUnit) throws {
    if let data = effect.state {
        guard let state = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AUError("Invalid saved state for \(effect.name).")
        }
        unit.fullState = state
    }
}

final class PullSource {
    var samples: UnsafeMutablePointer<Float>
    let frames: UInt32
    init(samples: UnsafeMutablePointer<Float>, frames: UInt32) { self.samples = samples; self.frames = frames }
    lazy var block: AURenderPullInputBlock = { [unowned self] _, _, frames, bus, data in
        guard bus == 0, frames == self.frames, data.pointee.mNumberBuffers == 2 else { return kAudioUnitErr_FormatNotSupported }
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        let bytes = Int(frames) * MemoryLayout<Float>.size
        for lane in 0..<2 {
            let source = self.samples.advanced(by: lane * Int(self.frames))
            if let destination = buffers[lane].mData {
                guard buffers[lane].mDataByteSize >= bytes else { return kAudioUnitErr_TooManyFramesToProcess }
                memcpy(destination, source, bytes)
            } else { buffers[lane].mData = UnsafeMutableRawPointer(source) }
            buffers[lane].mNumberChannels = 1; buffers[lane].mDataByteSize = UInt32(bytes)
        }
        return noErr
    }
}

final class Stage {
    let effect: AUEffect
    let wrapper: AVAudioUnit
    let unit: AUAudioUnit
    let render: AURenderBlock
    let pull: PullSource
    init(effect: AUEffect, wrapper: AVAudioUnit, input: UnsafeMutablePointer<Float>, frames: UInt32) {
        self.effect = effect; self.wrapper = wrapper
        let unit = wrapper.auAudioUnit
        self.unit = unit; render = unit.renderBlock; pull = PullSource(samples: input, frames: frames)
        _ = pull.block // Cache before render resources / processing.
    }
}

/// Prepared on the setup task, then exclusively owned by one rendering queue.
final class Renderer: @unchecked Sendable {
    let transport: OpaquePointer
    let frames: UInt32
    let scratch: UnsafeMutablePointer<Float>
    let first: UnsafeMutablePointer<Float>
    let second: UnsafeMutablePointer<Float>
    let list: UnsafeMutableAudioBufferListPointer
    var stages: [Stage] = []
    var latencySeconds: Float = 0
    var idleMicroseconds: UInt32 = 1000

    init(transport: OpaquePointer, frames: UInt32) {
        self.transport = transport; self.frames = frames
        let count = Int(frames) * 2
        scratch = .allocate(capacity: count); scratch.initialize(repeating: 0, count: count)
        first = .allocate(capacity: count); first.initialize(repeating: 0, count: count)
        second = .allocate(capacity: count); second.initialize(repeating: 0, count: count)
        list = AudioBufferList.allocate(maximumBuffers: 2); list.unsafeMutablePointer.pointee.mNumberBuffers = 2
    }
    @MainActor func prepare(request: AUWorkerRequest) async throws {
        guard request.sampleRate.isFinite, request.sampleRate > 0, frames >= 16, frames <= 256,
              frames & (frames - 1) == 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: request.sampleRate, channels: 2, interleaved: false) else {
            throw AUError("Invalid helper processing format.")
        }
        idleMicroseconds = UInt32(min(1000, max(50, Double(frames) / request.sampleRate * 250_000)))
        var latency: Double = 0
        for effect in request.chain.active {
            let wrapper = try await instantiateWrapper(effect)
            let unit = wrapper.auAudioUnit
            try restore(effect, unit: unit)
            guard unit.inputBusses.count >= 1, unit.outputBusses.count >= 1 else {
                throw AUError("\(effect.name) does not expose an audio input/output bus.")
            }
            unit.inputBusses[0].isEnabled = true; unit.outputBusses[0].isEnabled = true
            for index in 1..<unit.inputBusses.count { unit.inputBusses[index].isEnabled = false }
            for index in 1..<unit.outputBusses.count { unit.outputBusses[index].isEnabled = false }
            guard (1..<unit.inputBusses.count).allSatisfy({ !unit.inputBusses[$0].isEnabled }),
                  (1..<unit.outputBusses.count).allSatisfy({ !unit.outputBusses[$0].isEnabled }) else {
                throw AUError("\(effect.name) requires additional buses. Sidechains and multi-output effects are unsupported.")
            }
            try unit.inputBusses[0].setFormat(format)
            try unit.outputBusses[0].setFormat(format)
            unit.maximumFramesToRender = frames
            unit.isRenderingOffline = false
            // Native AUv2 editors can query this through the host callback bridge.
            // Capture only the mapping, which outlives every stage; no renderer cycle.
            let transport = self.transport
            unit.transportStateBlock = { flags, position, cycleStart, cycleEnd in
                let state = ABAUTransportSnapshot(transport)
                flags?.pointee = state.ready && !state.stopped && state.fault == 0 ? .moving : []
                position?.pointee = Double(state.processedFrames)
                cycleStart?.pointee = 0
                cycleEnd?.pointee = 0
                return true
            }
            let stage = Stage(effect: effect, wrapper: wrapper, input: first, frames: frames)
            try unit.allocateRenderResources()
            stages.append(stage)
            guard unit.latency.isFinite, unit.latency >= 0 else { throw AUError("Invalid plugin latency.") }
            if effect.enabled { latency += unit.latency }
            unit.shouldBypassEffect = !effect.enabled
        }
        guard latency.isFinite, latency < Double(Float.greatestFiniteMagnitude) else { throw AUError("Invalid chain latency.") }
        latencySeconds = Float(latency)
    }
    func processBlock(bypass: Bool = false) -> Bool {
        let count = Int(frames), bytes = UInt32(count * MemoryLayout<Float>.size)
        do {
            ABAUTransportHeartbeat(transport)
            guard ABAUTransportSnapshot(transport).inputFrames >= frames, ABAUWorkerSpace(transport) >= frames else {
                usleep(idleMicroseconds); return true // Helper only; HAL callbacks never wait.
            }
            let renderStart = ABAUTransportBeginBlock(transport, frames)
            defer { ABAUTransportEndBlock(transport, renderStart) }
            guard ABAUWorkerRead(transport, scratch, frames) == frames else { fail(-1); return false }
            for i in 0..<count { first[i] = scratch[i * 2]; first[count + i] = scratch[i * 2 + 1] }
            var input = first, output = second
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(ABAUTransportSnapshot(transport).processedFrames)
            timestamp.mFlags = .sampleTimeValid
            for stage in stages {
                stage.pull.samples = input
                for lane in 0..<2 {
                    list[lane] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: output.advanced(by: lane * count))
                    memset(list[lane].mData, 0, Int(bytes))
                }
                var flags = AudioUnitRenderActionFlags()
                let status = stage.render(&flags, &timestamp, frames, 0, list.unsafeMutablePointer, stage.pull.block)
                guard status == noErr else { fail(status); return false }
                guard list.unsafeMutablePointer.pointee.mNumberBuffers == 2 else { fail(kAudioUnitErr_FormatNotSupported); return false }
                for lane in 0..<2 {
                    guard list[lane].mNumberChannels == 1, list[lane].mDataByteSize == bytes,
                          let rendered = list[lane].mData else { fail(kAudioUnitErr_FormatNotSupported); return false }
                    memmove(output.advanced(by: lane * count), rendered, Int(bytes))
                }
                swap(&input, &output)
            }
            for i in 0..<count {
                let a = input[i], b = input[count + i]
                guard a.isFinite, b.isFinite else { fail(kAudioUnitErr_InvalidPropertyValue); return false }
                if !bypass { scratch[i * 2] = a; scratch[i * 2 + 1] = b }
            }
            guard ABAUWorkerWrite(transport, scratch, frames) == frames else { fail(-1); return false }
        }
        return true
    }
    func fail(_ status: OSStatus) { ABAUTransportFault(transport, status) }
    deinit {
        for stage in stages { stage.unit.deallocateRenderResources() }
        scratch.deallocate(); first.deallocate(); second.deallocate(); list.unsafeMutablePointer.deallocate()
    }
}

@main
enum Worker {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "scan" {
            let parent = getppid()
            let watch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watch.schedule(deadline: .now() + 1, repeating: 1)
            watch.setEventHandler { if getppid() != parent { exit(1) } }
            watch.resume()
            defer { watch.cancel() }
            let output = URL(fileURLWithPath: args[2])
            let effects = AUCatalog.effects { count in
                if count == 1 || count % 10 == 0 {
                    try? JSONEncoder().encode(count).write(to: output.deletingLastPathComponent().appendingPathComponent("progress.json"), options: .atomic)
                }
            }
            do {
                let cache = AUCatalogCache(effects: effects); try cache.validate()
                try JSONEncoder().encode(cache).write(to: output, options: .atomic)
                exit(0)
            } catch { exit(1) }
        }
        guard args.count >= 4 else { exit(2) }
        if args[1] == "edit" {
            Editor.launch(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
            NSApplication.shared.run()
            return
        }
        guard args[1] == "render", let transport = ABAUTransportOpen(args[2]) else { exit(2) }
        let parent = getppid()
        let parentWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        parentWatch.schedule(deadline: .now() + 1, repeating: 1)
        parentWatch.setEventHandler {
            if getppid() != parent { exit(1) }
        }
        parentWatch.resume()
        Task {
            do {
                let request = try JSONDecoder().decode(AUWorkerRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
                try request.chain.validate()
                let renderer = Renderer(transport: transport, frames: request.blockFrames)
                try await renderer.prepare(request: request)
                LiveHost(directory: URL(fileURLWithPath: args[3]).deletingLastPathComponent(), request: request, renderer: renderer).start()
            } catch {
                ABAUTransportFault(transport, -1)
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                ABAUTransportClose(transport); exit(1)
            }
        }
        withExtendedLifetime(parentWatch) {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run() // Dispatch AppKit events for editors of the running units.
        }
    }
}
