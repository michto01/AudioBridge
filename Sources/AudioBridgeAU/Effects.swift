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
public struct AUListing: Identifiable, Sendable {
    public let id: AUIdentity
    public let name: String
}
public enum AUCatalog {
    /// Registry metadata only; instantiation/editor/render code lives in the helper.
    public static func effects() -> [AUListing] {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        var component: AudioComponent?
        var result: [AUListing] = []
        while let next = AudioComponentFindNext(component, &description) {
            component = next
            var facts = AudioComponentDescription()
            guard AudioComponentGetDescription(next, &facts) == noErr else { continue }
            var name: Unmanaged<CFString>?
            guard AudioComponentCopyName(next, &name) == noErr, let name else { continue }
            result.append(AUListing(id: AUIdentity(type: facts.componentType, subtype: facts.componentSubType,
                manufacturer: facts.componentManufacturer), name: name.takeRetainedValue() as String))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
public struct AUError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct AUWorkerRequest: Codable, Sendable {
    public let chain: AUChain
    public let sampleRate: Double
    public let blockFrames: UInt32
    public init(chain: AUChain, sampleRate: Double, blockFrames: UInt32) {
        self.chain = chain; self.sampleRate = sampleRate; self.blockFrames = blockFrames
    }
}
