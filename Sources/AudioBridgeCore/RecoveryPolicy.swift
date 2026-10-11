import Foundation

public enum BridgeFailureKind: String, Sendable { case recoverable, actionRequired, unsafeTeardown }
public struct BridgeFailure: Error, LocalizedError, Sendable {
    public let message: String
    public let kind: BridgeFailureKind
    public init(_ message: String, kind: BridgeFailureKind) { self.message = message; self.kind = kind }
    public var errorDescription: String? { message }
}

/// Deterministic policy; the app supplies monotonic time and performs side effects.
public struct RecoveryPolicy: Sendable {
    public private(set) var desired = false
    public private(set) var blocked = false
    public private(set) var attempts = 0
    public private(set) var retryAt: Double?
    public private(set) var lastAttempt: Double?
    public init() {}
    public static func shouldResume(autoResume: Bool, desired: Bool) -> Bool { autoResume && desired }
    public mutating func start() { desired = true; blocked = false; attempts = 0; retryAt = nil }
    public mutating func stop() { desired = false; blocked = false; attempts = 0; retryAt = nil }
    public mutating func attempting(now: Double) { lastAttempt = now; retryAt = nil }
    public mutating func failed(_ kind: BridgeFailureKind, now: Double) {
        guard desired else { return }
        if kind != .recoverable { blocked = true; retryAt = nil; return }
        let delays: [Double] = [1, 2, 4, 8, 16, 30]
        retryAt = now + delays[min(attempts, delays.count - 1)]
        attempts = min(attempts + 1, delays.count)
    }
    public mutating func deviceChanged(now: Double) {
        guard desired, !blocked, let retryAt else { return }
        self.retryAt = min(retryAt, max(now, (lastAttempt ?? now) + 1))
    }
    public mutating func healthy(seconds: Double) {
        if desired && !blocked && seconds >= 20 { attempts = 0 }
    }
    public func due(now: Double) -> Bool { desired && !blocked && retryAt.map { now >= $0 } == true }
}
