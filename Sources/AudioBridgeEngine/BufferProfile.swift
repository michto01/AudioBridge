import Foundation

/// Provisional FIFO margins. These neither configure HAL buffers nor compensate clock drift.
public enum BufferProfile: String, CaseIterable, Sendable {
    case low, balanced, robust
    public var title: String { rawValue.capitalized }
    public func targetFrames(deviceBuffer: UInt32) -> UInt32 {
        switch self {
        case .low: return max(64, deviceBuffer)
        case .balanced: return max(64, deviceBuffer * 2)
        case .robust: return max(256, deviceBuffer * 4)
        }
    }
}
