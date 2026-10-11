import Foundation

public enum GainSettings {
    public static let range: ClosedRange<Double> = -60...12
    public static func amplitude(decibels: Double) -> Float {
        let db = decibels.isFinite ? min(12, max(-60, decibels)) : 0
        return Float(pow(10, db / 20))
    }
}
