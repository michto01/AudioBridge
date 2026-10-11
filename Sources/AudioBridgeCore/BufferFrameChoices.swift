public enum BufferFrameChoices {
    /// Prefer the actual driver value. A draft fallback never writes hardware.
    public static func initialRequest(current: UInt32?, range: ValueRange?) -> Int {
        if let current, current > 0 { return Int(current) }
        guard let range, range.minimum.isFinite, range.maximum.isFinite,
              range.minimum >= 1, range.maximum <= Double(UInt32.max), range.minimum <= range.maximum else { return 128 }
        let lower = Int(range.minimum.rounded(.up)), upper = Int(range.maximum.rounded(.down))
        guard lower <= upper else { return 128 }
        return max(lower, min(128, upper))
    }
    /// Common choices, not an assertion about a driver's discrete supported values.
    public static let common: [Int] = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768]
}
