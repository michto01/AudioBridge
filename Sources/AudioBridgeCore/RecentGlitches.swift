/// Cumulative counters remain intact. Only the presentation recovers after
/// twenty continuously healthy seconds on a monotonic clock. Queue recentering
/// and rebuffer bookkeeping alone are not evidence of lost frames.
public struct DeliveryCounters: Equatable, Sendable {
    public let underruns, overruns, formatFaults, rebuffers, recentered: UInt64
    public init(underruns: UInt64 = 0, overruns: UInt64 = 0, formatFaults: UInt64 = 0,
                rebuffers: UInt64 = 0, recentered: UInt64 = 0) {
        self.underruns = underruns; self.overruns = overruns; self.formatFaults = formatFaults
        self.rebuffers = rebuffers; self.recentered = recentered
    }
}

public struct RecentGlitches: Sendable {
    private var previous = DeliveryCounters()
    private var healthySince: Double?
    private var everHealthy = false
    public private(set) var active = false
    public private(set) var cleanSeconds: Double = 0
    public init() {}
    public mutating func update(now: Double, healthy: Bool, counters: DeliveryCounters) {
        guard now.isFinite else { return }
        let deliveryLossChanged = counters.underruns != previous.underruns
            || counters.overruns != previous.overruns
            || counters.formatFaults != previous.formatFaults
        if deliveryLossChanged {
            active = true; healthySince = nil; cleanSeconds = 0
        }
        previous = counters
        if !healthy {
            if everHealthy { active = true }
            healthySince = nil; cleanSeconds = 0
            return
        }
        everHealthy = true
        if let start = healthySince { if now < start { healthySince = now } }
        else { healthySince = now }
        cleanSeconds = max(0, now - (healthySince ?? now))
        if cleanSeconds >= 20 { active = false }
    }
}
