import AudioToolbox
import Foundation

public struct AUIdentity: Codable, Hashable, Sendable {
    public var type: UInt32
    public var subtype: UInt32
    public var manufacturer: UInt32
    public init(type: UInt32, subtype: UInt32, manufacturer: UInt32) {
        self.type = type; self.subtype = subtype; self.manufacturer = manufacturer
    }
    public var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype,
            componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}
public struct AUEffect: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var identity: AUIdentity
    public var name: String
    public var enabled: Bool
    public var state: Data?
    public init(identity: AUIdentity, name: String) {
        id = UUID(); self.identity = identity; self.name = name; enabled = true; state = nil
    }
}
extension AUEffect {
    /// Stable diagnostic identity; never use Swift's process-randomized Hasher.
    public var timingIdentity: UInt64 {
        id.uuidString.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
public struct AUChain: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var effects: [AUEffect] = []
    public init() {}
    public var active: [AUEffect] { effects.filter(\.enabled) }
    public func validate() throws {
        guard schemaVersion == 1, effects.count <= 8, Set(effects.map(\.id)).count == effects.count,
              effects.allSatisfy({ $0.identity.type == kAudioUnitType_Effect && ($0.state?.count ?? 0) <= 8 * 1024 * 1024 }) else {
            throw AUError("Unsupported or invalid AU chain. Saved data is retained.")
        }
    }
}
public struct AUListing: Identifiable, Codable, Sendable {
    public let id: AUIdentity
    public let name: String
    public init(id: AUIdentity, name: String) { self.id = id; self.name = name }
    /// Match all query words against the registry's vendor/effect display name.
    /// This reads cached metadata only; searching never instantiates a plugin.
    public func matchesSearch(_ query: String) -> Bool {
        let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
        return words.allSatisfy { normalizedName.contains($0) }
    }
}
public struct AUCatalogCache: Codable, Sendable {
    public let schemaVersion: Int
    public let scannedAt: Date
    public let effects: [AUListing]
    public init(effects: [AUListing], scannedAt: Date = Date()) { schemaVersion = 1; self.scannedAt = scannedAt; self.effects = effects }
    public func validate() throws {
        guard schemaVersion == 1, scannedAt.timeIntervalSince1970.isFinite, effects.count <= 10000,
              Set(effects.map(\.id)).count == effects.count,
              effects.allSatisfy({ $0.id.type == kAudioUnitType_Effect && !$0.name.isEmpty && $0.name.count <= 1024 }) else {
            throw AUError("Invalid cached Audio Unit catalog.")
        }
    }
}
public enum AUCatalog {
    /// Registry metadata only; instantiation/editor/render code lives in the helper.
    public static func effects(progress: ((Int) -> Void)? = nil) -> [AUListing] {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        var component: AudioComponent?
        var result: [AUListing] = []
        var seen: Set<AUIdentity> = []
        while let next = AudioComponentFindNext(component, &description) {
            component = next
            var facts = AudioComponentDescription()
            guard AudioComponentGetDescription(next, &facts) == noErr else { continue }
            var name: Unmanaged<CFString>?
            guard AudioComponentCopyName(next, &name) == noErr, let name else { continue }
            let displayName = name.takeRetainedValue() as String
            let identity = AUIdentity(type: facts.componentType, subtype: facts.componentSubType, manufacturer: facts.componentManufacturer)
            guard seen.insert(identity).inserted else { continue }
            result.append(AUListing(id: identity, name: displayName))
            progress?(result.count)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
public struct AUError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum AUBlockSizing {
    public static func frames(startupFill: UInt32) throws -> UInt32 {
        guard startupFill >= 16, startupFill <= 32768 else { throw AUError("Startup fill must be 16–32768 frames.") }
        var block: UInt32 = 16
        while block < 256, block * 2 <= startupFill { block *= 2 }
        return block
    }
}
public struct AUWorkerRequest: Codable, Sendable {
    public let chain: AUChain
    public let sampleRate: Double
    public let blockFrames: UInt32
    public let bypass: Bool?
    public let effectsProcessingEnabled: Bool?
    public init(chain: AUChain, sampleRate: Double, blockFrames: UInt32, bypass: Bool = false, effectsProcessingEnabled: Bool = true) {
        self.chain = chain; self.sampleRate = sampleRate; self.blockFrames = blockFrames; self.bypass = bypass
        self.effectsProcessingEnabled = effectsProcessingEnabled
    }
}
public struct AULiveCommand: Codable, Sendable {
    public var id = UUID()
    public let chain: AUChain?
    public let edit: UUID?
    public let bypass: Bool?
    public init(chain: AUChain? = nil, edit: UUID? = nil, bypass: Bool? = nil) { self.chain = chain; self.edit = edit; self.bypass = bypass }
}
public struct AULiveResponse: Codable, Sendable {
    public let id: UUID
    public let effect: AUEffect?
    public let error: String?
    public init(id: UUID, effect: AUEffect? = nil, error: String? = nil) { self.id = id; self.effect = effect; self.error = error }
}
