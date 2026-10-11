import Foundation

public struct EndpointSelection: Codable, Equatable, Sendable {
    public var uid: String?
    /// Physical channel indices are one-based. Nil means deliberately unconfigured.
    public var lane1: Int?
    public var lane2: Int?
    public init(uid: String? = nil, lane1: Int? = nil, lane2: Int? = nil) {
        self.uid = uid; self.lane1 = lane1; self.lane2 = lane2
    }
    public func issue(in devices: [DeviceFacts], direction: AudioDirection) -> String? {
        guard let uid else { return "\(direction.rawValue.capitalized) is unconfigured." }
        guard let device = devices.first(where: { $0.uid == uid }) else {
            return "Selected \(direction.rawValue) is missing; its UID is retained."
        }
        guard device.alive == true else { return "Selected \(direction.rawValue) liveness is unavailable or false." }
        guard let count = device.facts(for: direction).channelCount, count > 0 else {
            return "Selected \(direction.rawValue) has no confirmed channels."
        }
        guard let lane1, let lane2 else { return "Choose both physical \(direction.rawValue) channels." }
        let channels = device.facts(for: direction).physicalChannels
        guard channels.contains(lane1), channels.contains(lane2) else {
            return "Selected \(direction.rawValue) channel is unavailable; mapping is retained."
        }
        let streams = device.facts(for: direction).streams
        guard [lane1, lane2].allSatisfy({ channel in
            streams.contains { stream in
                guard let start = stream.startingChannel, let format = stream.virtualFormat,
                      start > 0, format.isPCM else { return false }
                return UInt64(channel) >= UInt64(start)
                    && UInt64(channel) < UInt64(start) + UInt64(format.channels)
            }
        }) else {
            return "Selected \(direction.rawValue) PCM format is unsupported or unknown."
        }
        return nil
    }
}

public struct RouteSelection: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var input = EndpointSelection()
    public var output = EndpointSelection()
    public var inputMix: [InputPatch] = []
    public var outputMap: [OutputPatch] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, input, output, inputMix, outputMap }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        input = try c.decode(EndpointSelection.self, forKey: .input)
        output = try c.decode(EndpointSelection.self, forKey: .output)
        if schemaVersion == 1 { inputMix = []; outputMap = [] }
        else {
            inputMix = try c.decode([InputPatch].self, forKey: .inputMix)
            outputMap = try c.decode([OutputPatch].self, forKey: .outputMap)
        }
    }
}

/// A future schema/corrupt payload is never silently reset or overwritten.
public struct SelectionStore {
    private let defaults: UserDefaults
    private let key = "AudioBridge.routeSelection"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> RouteSelection {
        guard let data = defaults.data(forKey: key) else { return RouteSelection() }
        var result = try JSONDecoder().decode(RouteSelection.self, from: data)
        if result.schemaVersion == 1 {
            let matrix = try defaults.data(forKey: "AudioBridge.matrix").map { try JSONDecoder().decode(ChannelMatrix.self, from: $0) } ?? .identity
            guard matrix.isValid else { throw StoreError.invalidRouting }
            var inputs: [Int: InputPatch] = [:]
            for (channel, l, r) in [(result.input.lane1, matrix.a, matrix.c), (result.input.lane2, matrix.b, matrix.d)] {
                if let channel {
                    var patch = inputs[channel] ?? InputPatch(channel: channel)
                    patch.left += l; patch.right += r; inputs[channel] = patch
                }
            }
            result.inputMix = inputs.values.sorted { $0.channel < $1.channel }
            if let channel = result.output.lane1 { result.outputMap.append(OutputPatch(channel: channel, source: .left)) }
            if let channel = result.output.lane2 {
                if let index = result.outputMap.firstIndex(where: { $0.channel == channel }) { result.outputMap[index].source = .mono }
                else { result.outputMap.append(OutputPatch(channel: channel, source: .right)) }
            }
            result.schemaVersion = 2
            result.input.lane1 = nil; result.input.lane2 = nil
            result.output.lane1 = nil; result.output.lane2 = nil
            guard result.patchesValid else { throw StoreError.invalidRouting }
            // Save backup once, then the complete migrated configuration. Old matrix is retained.
            if defaults.data(forKey: "AudioBridge.routeSelection.v1Backup") == nil { defaults.set(data, forKey: "AudioBridge.routeSelection.v1Backup") }
            try save(result)
        }
        guard result.schemaVersion == 2 else { throw StoreError.unsupportedSchema(result.schemaVersion) }
        guard result.patchesValid else { throw StoreError.invalidRouting }
        return result
    }
    public func save(_ selection: RouteSelection) throws {
        guard selection.schemaVersion == 2 else { throw StoreError.unsupportedSchema(selection.schemaVersion) }
        guard selection.patchesValid else { throw StoreError.invalidRouting }
        defaults.set(try JSONEncoder().encode(selection), forKey: key)
    }
    public enum StoreError: Error { case unsupportedSchema(Int), invalidRouting }
}
