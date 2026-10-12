import AudioBridgeAUViews
import AppKit
import AudioBridgeAU
import AudioBridgeRealtime
import AudioToolbox
import AVFAudio
import CoreAudioKit
import Foundation
import Darwin

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

/// The mapping outlives the renderer; the observer invokes only a C atomic store.
private struct LatencySignal: @unchecked Sendable {
    let transport: OpaquePointer
    func mark() { ABAUTransportLatencyChanged(transport) }
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
    let timingIdentity: UInt64
    let pull: PullSource
    let pullBlock: AURenderPullInputBlock
    let contextObserver: UnsafeMutableRawPointer?
    var latencyObservation: NSKeyValueObservation?
    init(effect: AUEffect, wrapper: AVAudioUnit, input: UnsafeMutablePointer<Float>, frames: UInt32) {
        self.effect = effect; self.wrapper = wrapper; timingIdentity = effect.timingIdentity
        let unit = wrapper.auAudioUnit
        self.unit = unit; render = unit.renderBlock; pull = PullSource(samples: input, frames: frames)
        contextObserver = ABCreateRenderContextObserver(unit)
        pullBlock = pull.block // No lazy getter or new closure on render thread.
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
    var blockBudgetNanoseconds: UInt64 = 0

    init(transport: OpaquePointer, frames: UInt32) {
        self.transport = transport; self.frames = frames
        let count = Int(frames) * 2
        scratch = .allocate(capacity: count); scratch.initialize(repeating: 0, count: count)
        first = .allocate(capacity: count); first.initialize(repeating: 0, count: count)
        second = .allocate(capacity: count); second.initialize(repeating: 0, count: count)
        list = AudioBufferList.allocate(maximumBuffers: 2); list.unsafeMutablePointer.pointee.mNumberBuffers = 2
    }
    @MainActor func prepare(request: AUWorkerRequest) async throws {
        guard request.sampleRate.isFinite, request.sampleRate > 0, frames >= 16, frames <= 1024,
              frames & (frames - 1) == 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: request.sampleRate, channels: 2, interleaved: false) else {
            throw AUError("Invalid helper processing format.")
        }
        let budget = Double(frames) / request.sampleRate * 1_000_000_000
        guard budget.isFinite, budget >= 1, budget < Double(UInt64.max) else {
            throw AUError("Invalid helper block duration.")
        }
        blockBudgetNanoseconds = UInt64(budget)
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
                flags?.pointee = ABAUTransportMoving(transport) ? .moving : []
                position?.pointee = Double(ABAUTransportProcessedFrames(transport))
                cycleStart?.pointee = 0
                cycleEnd?.pointee = 0
                return true
            }
            try unit.allocateRenderResources()
            // Cache render/pull blocks after the unit has its processing resources.
            let stage = Stage(effect: effect, wrapper: wrapper, input: first, frames: frames)
            let signal = LatencySignal(transport: transport)
            stage.latencyObservation = unit.observe(\.latency, options: [.new]) { _, _ in
                signal.mark()
            }
            stages.append(stage)
            guard unit.latency.isFinite, unit.latency >= 0 else { throw AUError("Invalid plugin latency.") }
            if effect.enabled { latency += unit.latency }
            unit.shouldBypassEffect = !effect.enabled
        }
        guard latency.isFinite, latency < Double(Float.greatestFiniteMagnitude) else { throw AUError("Invalid chain latency.") }
        latencySeconds = Float(latency)
    }
    func installRenderContext() {
        let group = ABAUTransportWorkgroup(transport)
        for stage in stages {
            if let observer = stage.contextObserver { ABApplyRenderContextObserver(observer, group) }
        }
    }
    func processBlock(bypass: Bool = false, effectsProcessingEnabled: Bool = true) -> Bool {
        let count = Int(frames), bytes = UInt32(count * MemoryLayout<Float>.size)
        do {
            ABAUTransportHeartbeat(transport)
            guard ABAUTransportQueues(transport).inputFrames >= frames, ABAUWorkerSpace(transport) >= frames else {
                return true // Driver waits for a signaled full block; HAL never waits.
            }
            let renderStart = ABAUTransportBeginBlock(transport, frames)
            defer { ABAUTransportEndBlock(transport, renderStart) }
            guard ABAUWorkerRead(transport, scratch, frames) == frames else { fail(-1); return false }
            // Explicit DSP suspension: retain loaded units/settings for live
            // re-enable, but never invoke their pull/render blocks while off.
            if !effectsProcessingEnabled || stages.isEmpty {
                guard ABAUWorkerWrite(transport, scratch, frames) == frames else { fail(-1); return false }
                return true
            }
            for i in 0..<count { first[i] = scratch[i * 2]; first[count + i] = scratch[i * 2 + 1] }
            var input = first, output = second
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(ABAUTransportProcessedFrames(transport))
            timestamp.mFlags = .sampleTimeValid
            for index in stages.indices {
                let stage = stages[index]
                stage.pull.samples = input
                for lane in 0..<2 {
                    list[lane] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: output.advanced(by: lane * count))
                    memset(list[lane].mData, 0, Int(bytes))
                }
                var flags = AudioUnitRenderActionFlags()
                let stageStart = ABAUTransportBeginStage(transport, UInt32(index), stage.timingIdentity)
                let status = stage.render(&flags, &timestamp, frames, 0, list.unsafeMutablePointer, stage.pullBlock)
                ABAUTransportEndStage(transport, UInt32(index), stageStart)
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
    @MainActor func refreshLatency() {
        // Notification-driven reads, on AppKit's thread. Never query plugin
        // properties periodically while DSP is busy. Legacy units that omit
        // KVO are refreshed when their editor closes.
        var total: Double = 0
        for stage in stages {
            let latency = stage.unit.latency
            guard latency.isFinite, latency >= 0 else { fail(kAudioUnitErr_InvalidPropertyValue); return }
            total += latency
        }
        guard total.isFinite, total < Double(Float.greatestFiniteMagnitude) else {
            fail(kAudioUnitErr_InvalidPropertyValue); return
        }
        let value = Float(total)
        if value != latencySeconds {
            latencySeconds = value
            ABAUTransportSetLatency(transport, value)
        }
    }
    func fail(_ status: OSStatus) { ABAUTransportFault(transport, status) }
    deinit {
        for stage in stages {
            stage.latencyObservation?.invalidate()
            if let observer = stage.contextObserver { ABDestroyRenderContextObserver(observer) }
            stage.unit.deallocateRenderResources()
        }
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
        guard args[1] == "render" else { exit(2) }
        if args.count >= 5, UInt32(args[4]) != ABAUTransportProtocolVersion() {
            FileHandle.standardError.write(Data("App/helper transport protocol mismatch. Quit AudioBridge and reopen the complete matching app bundle.\n".utf8))
            exit(64)
        }
        guard let transport = ABAUTransportOpen(args[2]) else {
            FileHandle.standardError.write(Data(("Unable to open AU shared memory: " + String(cString: ABAUTransportLastError()) + "\n").utf8))
            exit(2)
        }
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
                // Keep startup errors available to the parent without collecting
                // unbounded third-party stderr during unattended rendering.
                let nullError = open("/dev/null", O_WRONLY)
                if nullError >= 0 { _ = dup2(nullError, STDERR_FILENO); close(nullError) }
                try LiveHost(directory: URL(fileURLWithPath: args[3]).deletingLastPathComponent(), request: request, renderer: renderer).start()
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
