/// Local engine health only. Silence is never an error; no upstream/downstream claim.
public enum RoutingActivity: String, Sendable, CaseIterable {
    case idle, starting, running, degraded, actionRequired
    /// Signal full-scale/clip counts deliberately do not enter routing health.
    public static func hasGlitches(underrunFrames: UInt64, overrunFrames: UInt64, formatFaults: UInt64) -> Bool {
        underrunFrames > 0 || overrunFrames > 0 || formatFaults > 0
    }
    public static func resolve(fault: Bool, requested: Bool, transitioning: Bool,
                               configured: Bool, configurationFault: Bool,
                               primed: Bool, callbacksFresh: Bool, deliveredFrames: Bool,
                               buffered: Bool, glitches: Bool) -> Self {
        if fault { return .actionRequired }
        if transitioning { return .starting }
        if requested {
            if !primed { return .starting }
            if !callbacksFresh || !buffered || glitches { return .degraded }
            return deliveredFrames ? .running : .starting
        }
        if configured && configurationFault { return .actionRequired }
        return .idle
    }
}
