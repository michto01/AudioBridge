import Foundation

public enum RemoteCommand: Equatable, Sendable {
    case start, stop
    case inputGain(Double), outputGain(Double), chainBypass(Bool)
}
/// Single control-queue owner. Every start/stop invalidates earlier callbacks.
public struct RemoteServiceEpoch {
    private var generation = UUID()
    private var enabled = false
    public init() {}
    public mutating func activate() -> UUID { generation = UUID(); enabled = true; return generation }
    public mutating func invalidate() { generation = UUID(); enabled = false }
    public func accepts(_ generation: UUID) -> Bool { enabled && generation == self.generation }
}
public enum RemoteOSCDecoder {
    public static func command(_ data: Data, gainRange: ClosedRange<Double>) -> RemoteCommand? {
        var cursor = 0
        func string() -> String? {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0),
                  let value = String(data: data[cursor..<end], encoding: .utf8) else { return nil }
            let next = ((end + 4) / 4) * 4
            guard next <= data.count, data[end..<next].allSatisfy({ $0 == 0 }) else { return nil }
            cursor = next; return value
        }
        guard let address = string(), let tags = string() else { return nil }
        if address == "/audiobridge/start" || address == "/audiobridge/stop" {
            guard tags == ",", cursor == data.count else { return nil }
            return address.hasSuffix("start") ? .start : .stop
        }
        guard cursor + 4 == data.count else { return nil }
        let word = data[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if address == "/audiobridge/effects/bypass" {
            let value = Int32(bitPattern: word)
            guard tags == ",i", value == 0 || value == 1 else { return nil }
            return .chainBypass(value == 1)
        }
        guard tags == ",f" else { return nil }
        let value = Double(Float(bitPattern: word))
        guard value.isFinite, gainRange.contains(value) else { return nil }
        switch address {
        case "/audiobridge/input/gain": return .inputGain(value)
        case "/audiobridge/output/gain": return .outputGain(value)
        default: return nil
        }
    }
}

public struct RemoteHTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}
public enum RemoteHTTPDecoder {
    public static func frame(_ data: Data) -> RemoteHTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return RemoteHTTPRequest(method: "INVALID", path: "", headers: headers, body: Data()) }
        let bodyStart = range.upperBound
        let bodyOffset = data.distance(from: data.startIndex, to: bodyStart)
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...16_384).contains(length), data.count >= bodyOffset + length else { return nil }
        return RemoteHTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers,
                           body: data.subdata(in: bodyOffset..<bodyOffset + length))
    }
}
