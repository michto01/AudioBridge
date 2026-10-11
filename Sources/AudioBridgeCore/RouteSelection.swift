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
    public var schemaVersion = 1
    public var input = EndpointSelection()
    public var output = EndpointSelection()
    public init() {}
}

/// A future schema/corrupt payload is never silently reset or overwritten.
public struct SelectionStore {
    private let defaults: UserDefaults
    private let key = "AudioBridge.routeSelection"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> RouteSelection {
        guard let data = defaults.data(forKey: key) else { return RouteSelection() }
        let result = try JSONDecoder().decode(RouteSelection.self, from: data)
        guard result.schemaVersion == 1 else { throw StoreError.unsupportedSchema(result.schemaVersion) }
        return result
    }
    public func save(_ selection: RouteSelection) throws {
        guard selection.schemaVersion == 1 else { throw StoreError.unsupportedSchema(selection.schemaVersion) }
        defaults.set(try JSONEncoder().encode(selection), forKey: key)
    }
    public enum StoreError: Error { case unsupportedSchema(Int) }
}
