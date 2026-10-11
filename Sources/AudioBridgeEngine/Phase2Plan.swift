import AudioBridgeCore
import AudioBridgeAU
import AudioBridgeRealtime
import Foundation

public struct Phase2Plan: Sendable {
    public struct Endpoint: Sendable {
        public let device: DeviceFacts
        public let format: StreamFormat
        public let lane1: UInt32
        public let lane2: UInt32
        var layout: ABLayout {
            ABLayout(channels: format.channels, lane1: lane1, lane2: lane2, planar: format.isNonInterleaved)
        }
    }
    public let input: Endpoint
    public let output: Endpoint
    public let sampleRate: Double
    public let capacity: UInt32
    public let prefill: UInt32
    public let auBlockFrames: UInt32

    public init(selection: RouteSelection, devices: [DeviceFacts], profile: BufferProfile = .balanced, bufferFrames: UInt32? = nil) throws {
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
        auBlockFrames = try AUBlockSizing.frames(startupFill: prefill)
        var size: UInt32 = 1024
        while size < max(prefill * 2, largestBuffer * 4) { size *= 2 }
        capacity = size
    }
    private static func endpoint(_ selection: EndpointSelection, direction: AudioDirection,
                                 devices: [DeviceFacts]) throws -> Endpoint {
        if let issue = selection.issue(in: devices, direction: direction) { throw PlanError(issue) }
        guard let device = devices.first(where: { $0.uid == selection.uid }),
              let lane1 = selection.lane1, let lane2 = selection.lane2 else {
            throw PlanError("Choose both devices and physical lanes.")
        }
        let facts = device.facts(for: direction)
        guard facts.streams.count == 1, let stream = facts.streams.first,
              let start = stream.startingChannel, let format = stream.virtualFormat else {
            throw PlanError("The initial path needs one confirmed PCM stream per direction. Multiple-stream routing is not implemented.")
        }
        guard format.isPCM, format.isFloat, format.isPacked, !format.isBigEndian,
              !format.isSignedInteger, format.bitsPerChannel == 32,
              format.channels > 0, format.channels <= 4096,
              format.framesPerPacket == 1,
              format.bytesPerFrame == (format.isNonInterleaved ? 4 : format.channels * 4),
              format.bytesPerPacket == format.bytesPerFrame,
              format.sampleRate.isFinite, format.sampleRate > 0,
              device.nominalSampleRate == format.sampleRate else {
            throw PlanError("The initial path supports native-endian packed Float32 PCM only. This format needs a conversion path that is not implemented yet.")
        }
        let expectedBuffers = format.isNonInterleaved
            ? Array(repeating: UInt32(1), count: Int(format.channels)) : [format.channels]
        guard facts.bufferChannelCounts == expectedBuffers else {
            throw PlanError("The reported IO buffer layout does not match the selected stream format.")
        }
        guard start > 0, lane1 >= Int(start), lane2 >= Int(start),
              lane1 - Int(start) < Int(format.channels), lane2 - Int(start) < Int(format.channels) else {
            throw PlanError("The selected physical channels do not belong to the confirmed stream.")
        }
        return Endpoint(device: device, format: format, lane1: UInt32(lane1 - Int(start)), lane2: UInt32(lane2 - Int(start)))
    }
    public struct PlanError: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
