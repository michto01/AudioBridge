import Foundation

public struct InputPatch: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { channel }
    public let channel: Int
    public var left: Double
    public var right: Double
    public init(channel: Int, left: Double = 0, right: Double = 0) {
        self.channel = channel; self.left = left; self.right = right
    }
    // 2 preserves legacy duplicated-input matrices whose coefficients add together.
    public var isValid: Bool { channel > 0 && [left, right].allSatisfy { $0.isFinite && (0...2).contains($0) } }
}

public enum StereoSource: String, Codable, Sendable, CaseIterable {
    case off, left, right, mono
    public var gains: (Float, Float) {
        switch self { case .off: return (0, 0); case .left: return (1, 0)
        case .right: return (0, 1); case .mono: return (1, 1) }
    }
    public var label: String {
        switch self { case .off: return "Off"; case .left: return "L"; case .right: return "R"; case .mono: return "L+R" }
    }
}

public struct OutputPatch: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { channel }
    public let channel: Int
    public var source: StereoSource
    public init(channel: Int, source: StereoSource) { self.channel = channel; self.source = source }
}

extension RouteSelection {
    public var patchesValid: Bool {
        inputMix.count <= 4096 && outputMap.count <= 4096
            && inputMix.allSatisfy(\.isValid) && outputMap.allSatisfy { $0.channel > 0 }
            && Set(inputMix.map(\.channel)).count == inputMix.count
            && Set(outputMap.map(\.channel)).count == outputMap.count
    }
    public func issue(in devices: [DeviceFacts], direction: AudioDirection) -> String? {
        guard patchesValid else { return "Saved routing matrix is invalid." }
        let endpoint = direction == .input ? input : output
        guard let uid = endpoint.uid else { return "\(direction.rawValue.capitalized) is unconfigured." }
        guard let device = devices.first(where: { $0.uid == uid }) else { return "Selected \(direction.rawValue) is missing; its UID is retained." }
        guard device.alive == true else { return "Selected \(direction.rawValue) liveness is unavailable or false." }
        let channels = device.facts(for: direction).physicalChannels
        let selected = direction == .input ? inputMix.filter { $0.left > 0 || $0.right > 0 }.map(\.channel)
            : outputMap.filter { $0.source != .off }.map(\.channel)
        guard !selected.isEmpty else { return direction == .input ? "Patch at least one input into Mix L or Mix R." : "Assign at least one physical output to L or R." }
        guard selected.allSatisfy(channels.contains) else { return "Selected \(direction.rawValue) channel is unavailable; mapping is retained." }
        return nil
    }
    public var headroomWarning: Bool {
        inputMix.reduce(0) { $0 + $1.left } > 1 || inputMix.reduce(0) { $0 + $1.right } > 1
            || outputMap.contains { $0.source == .mono }
    }
    public func mix(_ samples: [Int: Double]) -> (Double, Double) {
        inputMix.reduce((0, 0)) { ($0.0 + (samples[$1.channel] ?? 0) * $1.left,
                                  $0.1 + (samples[$1.channel] ?? 0) * $1.right) }
    }
}
