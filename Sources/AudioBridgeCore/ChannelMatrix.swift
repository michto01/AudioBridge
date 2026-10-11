import Foundation

public struct ChannelMatrix: Codable, Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1) { self.a = a; self.b = b; self.c = c; self.d = d }
    public var isValid: Bool { [a, b, c, d].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    public static let identity = ChannelMatrix()
    public static let swap = ChannelMatrix(a: 0, b: 1, c: 1, d: 0)
    public static let mono = ChannelMatrix(a: 0.5, b: 0.5, c: 0.5, d: 0.5)
    public static let inputOne = ChannelMatrix(a: 1, b: 0, c: 1, d: 0)
    public func process(left: Double, right: Double) -> (Double, Double) { (a * left + b * right, c * left + d * right) }
}
