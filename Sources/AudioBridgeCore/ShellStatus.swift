/// Phase 0 has no device configuration or audio engine.
public struct ShellStatus: Equatable, Sendable {
    public init() {}
    public let title = "Unconfigured"
    public let detail = "Audio routing is not yet implemented."
    public let meterText = "Unavailable"
    public let canStartRouting = false
}
