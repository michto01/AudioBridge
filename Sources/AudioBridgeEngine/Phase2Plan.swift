import AudioBridgeCore
import AudioBridgeAU
import AudioBridgeRealtime
import Foundation

public struct Phase2Plan: Sendable {
    public struct Endpoint: Sendable {
        public let device: DeviceFacts
        public let format: StreamFormat
        public let physicalChannels: [Int]
        public let addresses: [ABChannelAddress]
        public let bufferChannels: [UInt32]
        public func inputGains(_ selection: RouteSelection) -> [Float] {
            let patches = Dictionary(uniqueKeysWithValues: selection.inputMix.map { ($0.channel, $0) })
            return physicalChannels.flatMap { [Float(patches[$0]?.left ?? 0), Float(patches[$0]?.right ?? 0)] }
        }
        public func outputGains(_ selection: RouteSelection) -> [Float] {
            let patches = Dictionary(uniqueKeysWithValues: selection.outputMap.map { ($0.channel, $0.source) })
            return physicalChannels.flatMap { let pair = (patches[$0] ?? .off).gains; return [pair.0, pair.1] }
        }
    }
    public let input: Endpoint
    public let output: Endpoint
    public let sampleRate: Double
    public let capacity: UInt32
    public let prefill: UInt32
    public let auBlockFrames: UInt32

    public init(selection: RouteSelection, devices: [DeviceFacts], profile: BufferProfile = .balanced, bufferFrames: UInt32? = nil, auFrames: UInt32? = nil) throws {
        if let issue = selection.issue(in: devices, direction: .input) { throw PlanError(issue) }
        if let issue = selection.issue(in: devices, direction: .output) { throw PlanError(issue) }
        input = try Self.endpoint(selection.input, direction: .input, devices: devices)
        output = try Self.endpoint(selection.output, direction: .output, devices: devices)
        guard input.device.uid != output.device.uid else {
            throw PlanError("Select two separate devices for this initial audio path.")
        }
        guard input.format.sampleRate == output.format.sampleRate else {
            throw PlanError("The initial path needs matching device rates. Rate conversion is not implemented; device rates will not be changed automatically.")
        }
        sampleRate = input.format.sampleRate
        let largestBuffer = max(input.device.bufferFrames ?? 512, output.device.bufferFrames ?? 512)
        guard largestBuffer > 0, largestBuffer <= 4096 else {
            throw PlanError("The initial path supports callback buffers up to 4096 frames.")
        }
        prefill = bufferFrames ?? profile.targetFrames(deviceBuffer: largestBuffer)
        guard prefill >= max(16, largestBuffer), prefill <= 32768 else {
            throw PlanError("Bridge buffering must be between \(max(16, largestBuffer)) and 32768 frames for these devices.")
        }
        // Publish the first processed portion before finishing a capture burst.
        // Smaller batches trade more render calls for earlier ready audio;
        // explicit expert sizes remain untouched. Keep the 16–256 bounds.
        let automatic = try AUBlockSizing.frames(startupFill: min(prefill, max(16, largestBuffer / 2)))
        let block = auFrames ?? automatic
        guard block >= 16, block <= 1024, block & (block - 1) == 0, block <= prefill else {
            throw PlanError("AU blocks must be a power of two from 16 to 1024 frames and no larger than the FIFO reserve.")
        }
        auBlockFrames = block
        // Storage headroom, not another fill target. Only occupied frames add
        // queue delay; AU input/output each receive this bounded capacity.
        var size: UInt32 = 1024
        while size < max(prefill * 2, largestBuffer * 4) { size *= 2 }
        capacity = size
    }
    private static func endpoint(_ selection: EndpointSelection, direction: AudioDirection,
                                 devices: [DeviceFacts]) throws -> Endpoint {
        guard let device = devices.first(where: { $0.uid == selection.uid }), device.alive == true else {
            throw PlanError("Choose an available device explicitly.")
        }
        let facts = device.facts(for: direction)
        guard !facts.streams.isEmpty, facts.streams.count <= 4096 else { throw PlanError("No confirmed PCM stream topology.") }
        var channels: [Int] = [], addresses: [ABChannelAddress] = [], buffers: [UInt32] = []
        var first: StreamFormat?
        var lastPhysical = 0
        // Retain HAL stream order. Reject overlapping/reordered indices instead of guessing buffer identity.
        for stream in facts.streams {
            guard let start = stream.startingChannel, start > 0, Int(start) > lastPhysical,
                  let format = stream.virtualFormat else { throw PlanError("Ambiguous stream/channel ordering; routing cannot be mapped safely.") }
            guard format.isPCM, format.isFloat, format.isPacked, !format.isBigEndian,
                  !format.isSignedInteger, format.bitsPerChannel == 32,
                  format.channels > 0, format.channels <= 4096,
                  channels.count + Int(format.channels) <= 4096,
                  format.framesPerPacket == 1,
                  format.bytesPerFrame == (format.isNonInterleaved ? 4 : format.channels * 4),
                  format.bytesPerPacket == format.bytesPerFrame,
                  format.sampleRate.isFinite, format.sampleRate > 0,
                  device.nominalSampleRate == format.sampleRate else {
                throw PlanError("Routing supports native-endian packed Float32 streams at the device rate, up to 4096 physical channels. This format needs an unimplemented conversion path.")
            }
            first = first ?? format
            let buffer = UInt32(buffers.count)
            for offset in 0..<format.channels {
                channels.append(Int(start) + Int(offset))
                addresses.append(ABChannelAddress(buffer: buffer + (format.isNonInterleaved ? offset : 0),
                    offset: format.isNonInterleaved ? 0 : offset, stride: format.isNonInterleaved ? 1 : format.channels))
            }
            buffers += format.isNonInterleaved ? Array(repeating: UInt32(1), count: Int(format.channels)) : [format.channels]
            lastPhysical = Int(start) + Int(format.channels) - 1
        }
        guard buffers == facts.bufferChannelCounts, facts.channelCount == channels.count, let format = first else {
            throw PlanError("Reported IO buffers do not match the stream topology; routing cannot guess a layout.")
        }
        return Endpoint(device: device, format: format, physicalChannels: channels, addresses: addresses, bufferChannels: buffers)
    }
    public struct PlanError: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
