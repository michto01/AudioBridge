/// Cumulative counters remain intact. Only the presentation recovers after
/// five continuously healthy seconds on a monotonic clock. Recentered frames
/// are actual source discards; rebuffer bookkeeping alone is not sample loss.
public struct DeliveryCounters: Equatable, Sendable {
    public let underruns, overruns, formatFaults, rebuffers, recentered: UInt64
    public init(underruns: UInt64 = 0, overruns: UInt64 = 0, formatFaults: UInt64 = 0,
                rebuffers: UInt64 = 0, recentered: UInt64 = 0) {
        self.underruns = underruns; self.overruns = overruns; self.formatFaults = formatFaults
        self.rebuffers = rebuffers; self.recentered = recentered
    }
}

public struct RecentGlitches: Sendable {
    public static let warningRecoverySeconds = 5.0
    private var previous = DeliveryCounters()
    private var healthySince: Double?
    private var everHealthy = false
    public private(set) var active = false
    public private(set) var cleanSeconds: Double = 0
    public private(set) var reason: String?
    public init() {}
    public mutating func update(now: Double, healthy: Bool, unhealthyReason: String? = nil, counters: DeliveryCounters) {
        guard now.isFinite else { return }
        var reasons: [String] = []
        if counters.underruns > previous.underruns {
            reasons.append("Output underrun: \(counters.underruns - previous.underruns) frames lost")
        }
        if counters.overruns > previous.overruns {
            reasons.append("Input overrun: \(counters.overruns - previous.overruns) frames dropped")
        }
        if counters.recentered > previous.recentered {
            reasons.append("Queue recentering: \(counters.recentered - previous.recentered) source frames discarded")
        }
        if counters.formatFaults > previous.formatFaults {
            reasons.append("Audio format fault: \(counters.formatFaults - previous.formatFaults) new fault(s)")
        }
        if !reasons.isEmpty {
            active = true
            reason = reasons.joined(separator: " · ")
            healthySince = nil
            cleanSeconds = 0
        }
        previous = counters
        if !healthy {
            if everHealthy {
                active = true
                if reasons.isEmpty, let unhealthyReason { reason = unhealthyReason }
                else if reasons.isEmpty, reason == nil { reason = "Audio delivery is not yet healthy" }
            }
            healthySince = nil; cleanSeconds = 0
            return
        }
        everHealthy = true
        if let start = healthySince { if now < start { healthySince = now } }
        else { healthySince = now }
        cleanSeconds = max(0, now - (healthySince ?? now))
        if cleanSeconds >= Self.warningRecoverySeconds {
            active = false
            reason = nil
        }
    }
}
