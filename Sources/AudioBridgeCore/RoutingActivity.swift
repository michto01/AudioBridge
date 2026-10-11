/// Local engine health only. Silence is never an error; no upstream/downstream claim.
public enum RoutingActivity: String, Sendable, CaseIterable {
    case idle, starting, running, degraded, actionRequired
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
