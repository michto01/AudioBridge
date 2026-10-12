import AppKit
import AudioBridgeEngine
import Foundation
import Network
import Security
import SwiftUI

enum RemoteCommand {
    case start, stop
    case inputGain(Double), outputGain(Double), chainBypass(Bool)
}

@MainActor
final class RemoteControlServer: ObservableObject {
    @Published var httpEnabled = false
    @Published var oscEnabled = false
    @Published var httpPort = 8765
    @Published var oscPort = 9000
    @Published var feedbackHost = ""
    @Published var feedbackPort = 12321
    @Published var allowedOSCAddresses = ""
    @Published private(set) var token = ""
    @Published private(set) var status = "Remote services are off"
    @Published private(set) var httpStatus = "Stopped"
    @Published private(set) var oscStatus = "Stopped"

    var statusProvider: (() -> [String: Any])?
    var commandHandler: ((RemoteCommand) -> String?)?

    private var httpListener: NWListener?
    private var oscListener: NWListener?
    private var feedback: NWConnection?
    private let queue = DispatchQueue(label: "cz.bytelab.audiobridge.remote", qos: .utility)
    private var reportTimer: DispatchSourceTimer?
    private var storedToken: String? { Self.keychainToken() }

    init() {
        let defaults = UserDefaults.standard
        httpEnabled = defaults.bool(forKey: "AudioBridge.remote.httpEnabled")
        oscEnabled = defaults.bool(forKey: "AudioBridge.remote.oscEnabled")
        httpPort = defaults.integer(forKey: "AudioBridge.remote.httpPort").nonzero ?? 8765
        oscPort = defaults.integer(forKey: "AudioBridge.remote.oscPort").nonzero ?? 9000
        feedbackHost = defaults.string(forKey: "AudioBridge.remote.feedbackHost") ?? ""
        feedbackPort = defaults.integer(forKey: "AudioBridge.remote.feedbackPort").nonzero ?? 12321
        allowedOSCAddresses = defaults.string(forKey: "AudioBridge.remote.oscAllowlist") ?? ""
        token = Self.keychainToken() ?? ""
    }

    func saveSettings() { persistSettings() }
    func setHTTPRunning(_ running: Bool) {
        httpEnabled = running
        persistSettings()
        if running { startHTTPListener() }
        else { httpListener?.cancel(); httpListener = nil; httpStatus = "Stopped"; updateSummary() }
    }
    func setOSCRunning(_ running: Bool) {
        oscEnabled = running
        persistSettings()
        if running {
            startOSCListener(); configureFeedback(); startReporter()
        } else {
            oscListener?.cancel(); oscListener = nil; oscStatus = "Stopped"
            reportTimer?.cancel(); reportTimer = nil; feedback?.cancel(); feedback = nil
            updateSummary()
        }
    }
    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(httpEnabled, forKey: "AudioBridge.remote.httpEnabled")
        defaults.set(oscEnabled, forKey: "AudioBridge.remote.oscEnabled")
        defaults.set(httpPort, forKey: "AudioBridge.remote.httpPort")
        defaults.set(oscPort, forKey: "AudioBridge.remote.oscPort")
        defaults.set(feedbackHost, forKey: "AudioBridge.remote.feedbackHost")
        defaults.set(feedbackPort, forKey: "AudioBridge.remote.feedbackPort")
        defaults.set(allowedOSCAddresses, forKey: "AudioBridge.remote.oscAllowlist")
        if httpEnabled && token.isEmpty { regenerateToken() }
    }

    func regenerateToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { status = "Could not create API token (Security error \(result))"; return }
        let value = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard Self.saveKeychainToken(value) else { status = "Could not save API token to Keychain"; return }
        token = value
    }

    func apply() {
        stopListeners()
        guard httpEnabled || oscEnabled else { status = "Remote services are off"; return }
        guard (!httpEnabled || (1024...65535).contains(httpPort)),
              (!oscEnabled || (1024...65535).contains(oscPort)),
              (feedbackHost.isEmpty || (1024...65535).contains(feedbackPort)) else {
            status = "Enabled service ports must be between 1024 and 65535"; return
        }
        if httpEnabled && token.isEmpty { regenerateToken() }
        if httpEnabled && token.isEmpty { return }

        if httpEnabled { startHTTPListener() }
        if oscEnabled { startOSCListener() }
        if httpEnabled || oscEnabled {
            configureFeedback()
            startReporter()
        }
        updateSummary()
    }

    func copyToken() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string) }

    private func stopListeners() {
        reportTimer?.cancel(); reportTimer = nil
        feedback?.cancel(); feedback = nil
        httpListener?.cancel(); httpListener = nil
        oscListener?.cancel(); oscListener = nil
        httpStatus = "Stopped"; oscStatus = "Stopped"
    }
    private func updateStatus(_ value: String) { status = value }
    private func updateSummary() {
        status = "HTTP: \(httpEnabled ? httpStatus : "off") · OSC: \(oscEnabled ? oscStatus : "off")"
    }
    private func startHTTPListener() {
        guard (1024...65535).contains(httpPort) else { httpStatus = "Invalid port"; updateSummary(); return }
        if token.isEmpty { regenerateToken() }
        guard !token.isEmpty else { httpStatus = "Token unavailable"; updateSummary(); return }
        httpListener?.cancel()
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(httpPort))!)
            listener.newConnectionLimit = 16
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.httpStatus = Self.describe(state); self?.updateSummary() }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.acceptHTTP(connection) } }
            listener.start(queue: queue); httpListener = listener; httpStatus = "Starting"
        } catch { httpStatus = "Failed — \(error.localizedDescription)" }
        updateSummary()
    }
    private func startOSCListener() {
        guard (1024...65535).contains(oscPort) else { oscStatus = "Invalid port"; updateSummary(); return }
        oscListener?.cancel()
        do {
            let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: UInt16(oscPort))!)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.oscStatus = Self.describe(state); self?.updateSummary() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    connection.start(queue: self.queue); self.receiveOSC(connection)
                }
            }
            listener.start(queue: queue); oscListener = listener; oscStatus = "Starting"
        } catch { oscStatus = "Failed — \(error.localizedDescription)" }
        updateSummary()
    }

    private func configureFeedback() {
        guard oscEnabled, !feedbackHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(feedbackPort)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(feedbackHost), port: port, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.updateStatus("OSC feedback failed: \(error.localizedDescription)") }
            }
        }
        connection.start(queue: queue)
        feedback = connection
    }
    private func startReporter() {
        guard feedback != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.sendOSCStatus() }
        }
        timer.resume(); reportTimer = timer
    }
    private func sendOSCStatus() {
        guard let feedback, let payload = statusProvider?() else { return }
        let statusText = payload["status"] as? String ?? "Unknown"
        let running = (payload["running"] as? Bool ?? false) ? Int32(1) : Int32(0)
        let inL = Float(payload["inputLeft"] as? Double ?? 0)
        let inR = Float(payload["inputRight"] as? Double ?? 0)
        let outL = Float(payload["outputLeft"] as? Double ?? 0)
        let outR = Float(payload["outputRight"] as? Double ?? 0)
        let reports: [(String, Data)] = [
            ("/audiobridge/status", Self.oscMessage("/audiobridge/status", string: statusText)),
            ("/audiobridge/running", Self.oscMessage("/audiobridge/running", int: running)),
            ("/audiobridge/input/left", Self.oscMessage("/audiobridge/input/left", float: inL)),
            ("/audiobridge/input/right", Self.oscMessage("/audiobridge/input/right", float: inR)),
            ("/audiobridge/output/left", Self.oscMessage("/audiobridge/output/left", float: outL)),
            ("/audiobridge/output/right", Self.oscMessage("/audiobridge/output/right", float: outR))
        ]
        for (_, packet) in reports {
            feedback.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    private func acceptHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTP(connection, accumulated: Data())
    }
    private func receiveHTTP(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                if bytes.count > 16_384 { self.respond(connection, status: 413, object: ["error": "request too large"]); return }
                if let request = Self.parseHTTP(bytes) { self.handleHTTP(request, connection: connection) }
                else if complete || error != nil { self.respond(connection, status: 400, object: ["error": "incomplete request"]) }
                else { self.receiveHTTP(connection, accumulated: bytes) }
            }
        }
    }
    private struct HTTPRequest { let method: String; let path: String; let headers: [String: String]; let body: Data }
    private static func parseHTTP(_ data: Data) -> HTTPRequest? {
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
        if headers["transfer-encoding"] != nil { return HTTPRequest(method: "INVALID", path: "", headers: headers, body: Data()) }
        let bodyStart = range.upperBound
        let bodyOffset = data.distance(from: data.startIndex, to: bodyStart)
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...16_384).contains(length), data.count >= bodyOffset + length else { return nil }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers,
                           body: data.subdata(in: bodyOffset..<bodyOffset + length))
    }
    private func handleHTTP(_ request: HTTPRequest, connection: NWConnection) {
        guard request.headers["authorization"].map({ Self.constantTimeEqual($0, "Bearer \(token)") }) == true else {
            respond(connection, status: 401, object: ["error": "unauthorized"]); return
        }
        if request.method == "GET", request.path == "/api/v1/status" {
            respond(connection, status: 200, object: statusProvider?() ?? [:]); return
        }
        guard request.method == "POST", request.path == "/api/v1/control",
              let object = try? JSONSerialization.jsonObject(with: request.body),
              let body = object as? [String: Any],
              let commandName = body["command"] as? String,
              let command = Self.command(name: commandName, json: body) else {
            respond(connection, status: 404, object: ["error": "unknown endpoint or malformed command"]); return
        }
        if let error = commandHandler?(command) { respond(connection, status: 409, object: ["error": error]) }
        else { respond(connection, status: 200, object: ["ok": true]) }
    }
    private func respond(_ connection: NWConnection, status: Int, object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 413 ? "Payload Too Large" : (status == 409 ? "Conflict" : "Bad Request")))
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func receiveOSC(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                if let data, data.count <= 1024,
                   let source = connection.endpoint.hostAddress,
                   Self.allowed(source, by: self.allowedOSCAddresses),
                   let command = Self.parseOSC(data) { _ = self.commandHandler?(command) }
                if error == nil { self.receiveOSC(connection) } else { connection.cancel() }
            }
        }
    }

    private static func command(name: String, json: [String: Any]) -> RemoteCommand? {
        switch name {
        case "start": return .start
        case "stop": return .stop
        case "inputGain", "outputGain":
            guard let value = json["decibels"] as? Double, value.isFinite, GainSettings.range.contains(value) else { return nil }
            return name == "inputGain" ? .inputGain(value) : .outputGain(value)
        case "chainBypass":
            guard let value = json["bypassed"] as? Bool else { return nil }
            return .chainBypass(value)
        default: return nil
        }
    }
    private static func parseOSC(_ data: Data) -> RemoteCommand? {
        var cursor = 0
        guard let address = oscString(data, cursor: &cursor), address.hasPrefix("/audiobridge/") else { return nil }
        guard let typeTag = oscString(data, cursor: &cursor), typeTag.first == "," else { return nil }
        let types = String(typeTag.dropFirst())
        func number() -> Double? {
            guard cursor + 4 <= data.count else { return nil }
            let value = data[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            cursor += 4
            return Double(Float(bitPattern: value))
        }
        switch address {
        case "/audiobridge/start": return .start
        case "/audiobridge/stop": return .stop
        case "/audiobridge/input/gain": guard let n = number(), types == "f", n.isFinite, GainSettings.range.contains(n) else { return nil }; return .inputGain(n)
        case "/audiobridge/output/gain": guard let n = number(), types == "f", n.isFinite, GainSettings.range.contains(n) else { return nil }; return .outputGain(n)
        case "/audiobridge/effects/bypass": guard let n = number(), types == "i", n == 0 || n == 1 else { return nil }; return .chainBypass(n == 1)
        default: return nil
        }
    }
    private static func oscString(_ data: Data, cursor: inout Int) -> String? {
        guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0), let result = String(data: data[cursor..<end], encoding: .utf8) else { return nil }
        cursor = ((end + 4) / 4) * 4
        return result
    }
    private static func oscMessage(_ address: String, string value: String) -> Data { var d = oscPadded(address) + oscPadded(",s"); d += oscPadded(value); return d }
    private static func oscMessage(_ address: String, int value: Int32) -> Data { var d = oscPadded(address) + oscPadded(",i"); d.appendBE(UInt32(bitPattern: value)); return d }
    private static func oscMessage(_ address: String, float value: Float) -> Data { var d = oscPadded(address) + oscPadded(",f"); d.appendBE(value.bitPattern); return d }
    private static func oscPadded(_ value: String) -> Data { var d = Data(value.utf8); d.append(0); while d.count % 4 != 0 { d.append(0) }; return d }
    private static func allowed(_ source: String, by list: String) -> Bool {
        Set(list.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)).contains(source)
    }
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func describe(_ state: NWListener.State) -> String {
        switch state { case .ready: return "listening"; case .failed(let e): return "failed — \(e.localizedDescription)"; case .cancelled: return "stopped"; default: return "starting" }
    }
    private static func keychainToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cz.bytelab.audiobridge.remote-api", kSecAttrAccount as String: "bearer-token", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func saveKeychainToken(_ token: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cz.bytelab.audiobridge.remote-api", kSecAttrAccount as String: "bearer-token"]
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}

private extension NWEndpoint {
    var hostAddress: String? {
        guard case let .hostPort(host, _) = self else { return nil }
        var result = String(describing: host)
        for prefix in ["ipv4(", "ipv6("] where result.hasPrefix(prefix) { result.removeFirst(prefix.count); if result.hasSuffix(")") { result.removeLast() } }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 255)); append(UInt8((value >> 16) & 255)); append(UInt8((value >> 8) & 255)); append(UInt8(value & 255))
    }
}

struct RemoteSettingsView: View {
    @ObservedObject var remote: RemoteControlServer
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InfoGroupBox("HTTP API", message: httpHelp) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Enable HTTP", isOn: Binding(get: { remote.httpEnabled }, set: { remote.setHTTPRunning($0) }))
                            Spacer()
                            Text(remote.httpStatus).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Listen port")
                            TextField("8765", value: $remote.httpPort, format: .number.grouping(.never)).frame(width: 90)
                        }
                        Divider()
                        Text("Bearer token").font(.subheadline.weight(.semibold))
                        HStack {
                            Text(remote.token.isEmpty ? "Not generated" : remote.token)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                            Spacer()
                            Button("Copy") { remote.copyToken() }.disabled(remote.token.isEmpty)
                            Button("Regenerate") { remote.regenerateToken() }
                        }
                    }
                }
                .onChange(of: remote.httpPort) { _, _ in remote.saveSettings() }
                InfoGroupBox("OSC", message: oscHelp) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Enable OSC", isOn: Binding(get: { remote.oscEnabled }, set: { remote.setOSCRunning($0) }))
                            Spacer()
                            Text(remote.oscStatus).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Listen port")
                            TextField("9000", value: $remote.oscPort, format: .number.grouping(.never)).frame(width: 90)
                        }
                        TextField("Allowed source IPs (comma separated)", text: $remote.allowedOSCAddresses)
                        Divider()
                        Text("Companion feedback").font(.subheadline.weight(.semibold))
                        HStack { Text("Address"); TextField("192.168.1.10", text: $remote.feedbackHost) }
                        HStack {
                            Text("Port")
                            TextField("12321", value: $remote.feedbackPort, format: .number.grouping(.never)).frame(width: 90)
                        }
                    }
                }
                .onChange(of: remote.oscPort) { _, _ in remote.saveSettings() }
                .onChange(of: remote.feedbackHost) { _, _ in remote.saveSettings() }
                .onChange(of: remote.feedbackPort) { _, _ in remote.saveSettings() }
                .onChange(of: remote.allowedOSCAddresses) { _, _ in remote.saveSettings() }
            }.padding()
        }
    }
    private var httpHelp: String {
        "The switch starts/stops only HTTP. Settings save automatically. Cycle this switch after changing its port; regenerated tokens take effect immediately.\n\nStatus: GET http://<Mac-IP>:\(remote.httpPort)/api/v1/status\nControl: POST http://<Mac-IP>:\(remote.httpPort)/api/v1/control\nHeader: Authorization: Bearer <token>\n\nStatus includes endpoint names, routing state, linear meter peaks, gains in dB and chain bypass. OutputGain controls digital fallback only; it is rejected when writable device volume is available or its capability check is pending. Status includes outputLevelControl, applied outputGainDB and saved outputFallbackGainDB. Control JSON: {\"command\":\"start\"}, {\"command\":\"stop\"}, {\"command\":\"inputGain\",\"decibels\":-6}, {\"command\":\"outputGain\",\"decibels\":0}, {\"command\":\"chainBypass\",\"bypassed\":true}.\n\nHTTP has no encryption. Use a trusted LAN; macOS firewall/privacy may affect reachability. Tokens are stored in Keychain. No audio is sent.\n\nService report: \(remote.status)"
    }
    private var oscHelp: String {
        "The switch starts/stops only OSC. Settings save automatically. Cycle this switch after changing its port or Companion destination; allowlist edits take effect immediately. Commands are accepted only from exact allowlisted source IPs.\n\nCommands: /audiobridge/start, /audiobridge/stop (no arguments); /audiobridge/input/gain, /audiobridge/output/gain (float dB); /audiobridge/effects/bypass (integer 0 or 1).\n\nFeedback is sent every second to Companion: /audiobridge/status (string), /audiobridge/running (integer), /audiobridge/input/left, /audiobridge/input/right, /audiobridge/output/left, /audiobridge/output/right (float linear peaks).\n\nOSC has no cryptographic authentication. Use a trusted LAN. macOS firewall and Local Network privacy can affect delivery. No audio is sent.\n\nService report: \(remote.status)"
    }
}
