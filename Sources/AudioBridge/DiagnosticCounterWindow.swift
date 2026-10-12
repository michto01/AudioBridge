import AudioBridgeEngine

/// UI-only measurement baseline. Never reset engine counters, sample timestamps,
/// queue indices or fault state while callbacks and the AU worker use them.
struct DiagnosticCounterWindow {
    let snapshot: EngineSnapshot
    let baseline: EngineSnapshot?

    func value(_ path: KeyPath<EngineSnapshot, UInt64>) -> UInt64 {
        Self.difference(snapshot[keyPath: path], baseline?[keyPath: path] ?? 0)
    }
    func pairs(_ current: [UInt64], _ previous: [UInt64]?) -> String {
        current.enumerated().map { index, value in
            let old = previous.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? 0
            return Self.difference(value, old).formatted()
        }.joined(separator: " / ")
    }
    private static func difference(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }
}
