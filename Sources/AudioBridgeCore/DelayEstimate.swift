import Foundation

public struct DelayComponent: Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let frames: Double?
}

/// Accounting model only. Drivers and plugins report latency; physical transit
/// requires loopback measurement. Missing properties remain unknown, not zero.
public struct DelayEstimate: Sendable {
    public let sampleRate: Double
    public let components: [DelayComponent]
    public var knownFrames: Double { components.compactMap(\.frames).reduce(0, +) }
    public var complete: Bool { components.allSatisfy { $0.frames != nil } }
    public var totalMilliseconds: Double? { complete ? milliseconds(knownFrames) : nil }
    public func milliseconds(_ frames: Double) -> Double? {
        guard sampleRate.isFinite, sampleRate > 0, frames.isFinite, frames >= 0 else { return nil }
        return frames / sampleRate * 1000
    }
    public init(input: DeviceFacts?, output: DeviceFacts?, selection: RouteSelection,
                sampleRate: Double, captureQueue: UInt32, processedQueue: UInt32,
                inFlight: UInt32, lookahead: UInt32, auLatencySeconds: Double, bypassed: Bool) {
        self.sampleRate = sampleRate
        var rows: [DelayComponent] = []
        for (device, direction) in [(input, AudioDirection.input), (output, AudioDirection.output)] {
            let facts = device?.facts(for: direction)
            let channels = direction == .input
                ? selection.inputMix.filter { $0.left > 0 || $0.right > 0 }.map(\.channel)
                : selection.outputMap.filter { $0.source != .off }.map(\.channel)
            let streams = facts?.streams.filter { stream in
                guard let start = stream.startingChannel, let count = stream.virtualFormat?.channels else { return false }
                return channels.contains { $0 >= Int(start) && $0 < Int(start) + Int(count) }
            } ?? []
            let streamLatency = !streams.isEmpty && streams.allSatisfy { $0.latencyFrames != nil }
                ? streams.compactMap(\.latencyFrames).max().map(Double.init) : nil
            let prefix = direction.rawValue.capitalized
            rows += [DelayComponent(label: "\(prefix) device latency", frames: facts?.latencyFrames.map(Double.init)),
                     DelayComponent(label: "\(prefix) routed stream latency (maximum)", frames: streamLatency),
                     DelayComponent(label: "\(prefix) safety offset", frames: facts?.safetyOffsetFrames.map(Double.init)),
                     DelayComponent(label: "\(prefix) callback buffer allowance", frames: device?.bufferFrames.map(Double.init))]
        }
        rows += [DelayComponent(label: "Capture queue", frames: Double(captureQueue)),
                 DelayComponent(label: "AU block in flight", frames: Double(inFlight)),
                 DelayComponent(label: "Processed queue", frames: Double(processedQueue)),
                 DelayComponent(label: "Drift FIR lookahead allowance", frames: Double(lookahead)),
                 DelayComponent(label: "AU reported signal latency", frames: bypassed ? 0 : (auLatencySeconds.isFinite && auLatencySeconds >= 0 && sampleRate.isFinite && sampleRate > 0 ? auLatencySeconds * sampleRate : nil))]
        components = rows
    }
}
