import Foundation

public enum AudioDirection: String, Codable, Sendable, CaseIterable {
    case input, output
}

public struct ValueRange: Codable, Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public init(minimum: Double, maximum: Double) {
        self.minimum = minimum; self.maximum = maximum
    }
}

public struct StreamFormat: Codable, Equatable, Sendable {
    public let formatID: String
    public let sampleRate: Double
    public let channels: UInt32
    public let bitsPerChannel: UInt32
    public let bytesPerFrame: UInt32
    public let bytesPerPacket: UInt32
    public let framesPerPacket: UInt32
    public let flags: UInt32
    public let isPCM: Bool
    public let isFloat: Bool
    public let isSignedInteger: Bool
    public let isNonInterleaved: Bool
    public let isBigEndian: Bool
    public let isPacked: Bool
    public init(formatID: String, sampleRate: Double, channels: UInt32,
                bitsPerChannel: UInt32, bytesPerFrame: UInt32, bytesPerPacket: UInt32,
                framesPerPacket: UInt32, flags: UInt32, isPCM: Bool, isFloat: Bool,
                isSignedInteger: Bool, isNonInterleaved: Bool, isBigEndian: Bool, isPacked: Bool) {
        self.formatID = formatID; self.sampleRate = sampleRate; self.channels = channels
        self.bitsPerChannel = bitsPerChannel; self.bytesPerFrame = bytesPerFrame
        self.bytesPerPacket = bytesPerPacket; self.framesPerPacket = framesPerPacket
        self.flags = flags; self.isPCM = isPCM; self.isFloat = isFloat
        self.isSignedInteger = isSignedInteger; self.isNonInterleaved = isNonInterleaved
        self.isBigEndian = isBigEndian; self.isPacked = isPacked
    }
}

public struct RangedStreamFormat: Codable, Equatable, Sendable {
    public let format: StreamFormat
    public let sampleRates: ValueRange
    public init(format: StreamFormat, sampleRates: ValueRange) {
        self.format = format; self.sampleRates = sampleRates
    }
}

public struct StreamFacts: Codable, Equatable, Sendable {
    /// Runtime ID is diagnostic only; selections never persist it.
    public let runtimeID: UInt32
    public let startingChannel: UInt32?
    public let virtualFormat: StreamFormat?
    public let physicalFormat: StreamFormat?
    public let availableVirtualFormats: [RangedStreamFormat]
    public let availablePhysicalFormats: [RangedStreamFormat]
    public let latencyFrames: UInt32?
    public init(runtimeID: UInt32, startingChannel: UInt32?, virtualFormat: StreamFormat?,
                physicalFormat: StreamFormat?, availableVirtualFormats: [RangedStreamFormat],
                availablePhysicalFormats: [RangedStreamFormat], latencyFrames: UInt32? = nil) {
        self.runtimeID = runtimeID; self.startingChannel = startingChannel
        self.virtualFormat = virtualFormat; self.physicalFormat = physicalFormat
        self.availableVirtualFormats = availableVirtualFormats
        self.availablePhysicalFormats = availablePhysicalFormats
        self.latencyFrames = latencyFrames
    }
}

public struct DirectionFacts: Codable, Equatable, Sendable {
    public let channelCount: Int?
    public let bufferChannelCounts: [UInt32]
    public let preferredLayoutTag: UInt32?
    public let channelLabels: [UInt32]
    public let streams: [StreamFacts]
    public let latencyFrames: UInt32?
    public let safetyOffsetFrames: UInt32?
    /// Reported latency can change without invalidating callback topology.
    public func matchesRoutingTopology(_ other: DirectionFacts) -> Bool {
        channelCount == other.channelCount && bufferChannelCounts == other.bufferChannelCounts
            && preferredLayoutTag == other.preferredLayoutTag && channelLabels == other.channelLabels
            && streams.count == other.streams.count && zip(streams, other.streams).allSatisfy { a, b in
                a.runtimeID == b.runtimeID && a.startingChannel == b.startingChannel
                    && a.virtualFormat == b.virtualFormat && a.physicalFormat == b.physicalFormat
                    && a.availableVirtualFormats == b.availableVirtualFormats && a.availablePhysicalFormats == b.availablePhysicalFormats
            }
    }
    /// Stream starting indices can be non-contiguous (observed on an aggregate).
    /// A channel count is not necessarily the largest physical index.
    public var physicalChannels: [Int] {
        Array(Set(streams.flatMap { stream -> [Int] in
            guard let start = stream.startingChannel, start > 0,
                  let format = stream.virtualFormat, format.channels <= 4096 else { return [] }
            return (0..<Int(format.channels)).map { Int(start) + $0 }
        })).sorted()
    }
    public init(channelCount: Int? = nil, bufferChannelCounts: [UInt32] = [],
                preferredLayoutTag: UInt32? = nil, channelLabels: [UInt32] = [], streams: [StreamFacts] = [],
                latencyFrames: UInt32? = nil, safetyOffsetFrames: UInt32? = nil) {
        self.channelCount = channelCount; self.bufferChannelCounts = bufferChannelCounts
        self.preferredLayoutTag = preferredLayoutTag; self.channelLabels = channelLabels
        self.streams = streams
        self.latencyFrames = latencyFrames; self.safetyOffsetFrames = safetyOffsetFrames
    }
}

public struct DeviceFacts: Codable, Equatable, Sendable, Identifiable {
    public var id: String { uid }
    public let runtimeID: UInt32
    public let uid: String
    public let name: String
    public let transport: String?
    public let iconURL: URL?
    public let alive: Bool?
    public let nominalSampleRate: Double?
    public let availableSampleRates: [ValueRange]
    public let bufferFrames: UInt32?
    public let bufferFrameRange: ValueRange?
    public let clockDomain: UInt32?
    public let input: DirectionFacts
    public let output: DirectionFacts
    public let issues: [String]
    public init(runtimeID: UInt32, uid: String, name: String, transport: String? = nil,
                iconURL: URL? = nil,
                alive: Bool? = nil, nominalSampleRate: Double? = nil,
                availableSampleRates: [ValueRange] = [], bufferFrames: UInt32? = nil,
                bufferFrameRange: ValueRange? = nil, clockDomain: UInt32? = nil,
                input: DirectionFacts = .init(), output: DirectionFacts = .init(), issues: [String] = []) {
        self.runtimeID = runtimeID; self.uid = uid; self.name = name; self.transport = transport
        self.iconURL = iconURL
        self.alive = alive; self.nominalSampleRate = nominalSampleRate
        self.availableSampleRates = availableSampleRates; self.bufferFrames = bufferFrames
        self.bufferFrameRange = bufferFrameRange; self.clockDomain = clockDomain
        self.input = input; self.output = output; self.issues = issues
    }
    public func facts(for direction: AudioDirection) -> DirectionFacts {
        direction == .input ? input : output
    }
}

public struct CatalogSnapshot: Codable, Sendable {
    public let devices: [DeviceFacts]
    public let issues: [String]
    public init(devices: [DeviceFacts], issues: [String] = []) {
        self.devices = devices; self.issues = issues
    }
}
