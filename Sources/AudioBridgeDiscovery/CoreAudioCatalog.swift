import AudioBridgeCore
import CoreAudio
import Foundation

/// HAL discovery and explicit operator-requested device controls. Never opens IO,
/// writes stream ASBDs, or changes system defaults. Explicit device-wide rate
/// and buffer requests are performed only while the app's route is stopped.
public enum CoreAudioCatalog {
    public struct OutputVolume: Equatable, Sendable {
        public let scalar: Float
        public let writable: Bool
    }

    /// Reads the selected device's master output volume control, if its driver exposes one.
    public static func outputVolume(uid: String) throws -> OutputVolume? {
        guard let device = try snapshot().devices.first(where: { $0.uid == uid }), device.alive == true,
              try string(device.runtimeID, kAudioDevicePropertyDeviceUID) == uid else {
            throw ProbeError.invalid("Selected output device is unavailable or its identity changed.")
        }
        var property = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device.runtimeID, &property) else { return nil }
        var scalar: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        try check(AudioObjectGetPropertyData(device.runtimeID, &property, 0, nil, &size, &scalar), device.runtimeID, property.mSelector)
        guard size == MemoryLayout<Float>.size, scalar.isFinite else {
            throw ProbeError.invalid("Selected output returned an invalid master volume value.")
        }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device.runtimeID, &property, &settable)
        return OutputVolume(scalar: min(1, max(0, scalar)), writable: status == noErr && settable.boolValue)
    }

    /// Explicit user command; device volume is shared with system audio and other clients.
    public static func setOutputVolume(uid: String, scalar: Float) throws -> Float {
        guard scalar.isFinite, (0...1).contains(scalar),
              let device = try snapshot().devices.first(where: { $0.uid == uid }), device.alive == true,
              try string(device.runtimeID, kAudioDevicePropertyDeviceUID) == uid else {
            throw ProbeError.invalid("Selected output device is unavailable, identity changed, or the volume value is invalid.")
        }
        var property = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device.runtimeID, &property),
              AudioObjectIsPropertySettable(device.runtimeID, &property, &settable) == noErr,
              settable.boolValue else {
            throw ProbeError.invalid("Selected output does not expose a writable master volume control.")
        }
        var requested = scalar
        try check(AudioObjectSetPropertyData(device.runtimeID, &property, 0, nil, UInt32(MemoryLayout<Float>.size), &requested), device.runtimeID, property.mSelector)
        return try scalarValue(device.runtimeID, property.mSelector, scope: property.mScope)
    }

    public static func rateIsSettable(_ id: UInt32) -> Bool {
        var property = address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &property, &settable) == noErr && settable.boolValue
    }
    /// Explicit stopped-route request; re-resolve the UID before changing hardware.
    public static func setNominalRate(uid: String, rate: Double) throws -> Double {
        guard rate.isFinite, rate > 0,
              let device = try snapshot(selectedUIDs: [uid]).devices.first(where: { $0.uid == uid }),
              device.alive == true, device.availableSampleRates.contains(where: { rate >= $0.minimum && rate <= $0.maximum }),
              rateIsSettable(device.runtimeID), try string(device.runtimeID, kAudioDevicePropertyDeviceUID) == uid else {
            throw ProbeError.invalid("Selected device cannot accept this sample rate. Check Audio MIDI Setup or use Expert mode.")
        }
        var property = address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal)
        var value = rate
        try check(AudioObjectSetPropertyData(device.runtimeID, &property, 0, nil, UInt32(MemoryLayout<Double>.size), &value), device.runtimeID, property.mSelector)
        return try scalar(device.runtimeID, property.mSelector, initial: Double(0))
    }
    public static func bufferIsSettable(_ id: UInt32) -> Bool {
        var property = address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &property, &settable) == noErr && settable.boolValue
    }

    /// Explicit user command only; a device-wide change can affect other audio applications.
    public static func setBufferFrames(uid: String, frames: UInt32) throws -> UInt32 {
        guard let device = try snapshot().devices.first(where: { $0.uid == uid }), device.alive == true,
              let range = device.bufferFrameRange, range.minimum.isFinite, range.maximum.isFinite,
              Double(frames) >= range.minimum, Double(frames) <= range.maximum,
              bufferIsSettable(device.runtimeID) else {
            throw ProbeError.invalid("Selected device is unavailable or its buffer size is not writable/in range.")
        }
        guard try string(device.runtimeID, kAudioDevicePropertyDeviceUID) == uid else {
            throw ProbeError.invalid("Device identity changed; refresh and try again.")
        }
        var property = address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        var value = frames
        try check(AudioObjectSetPropertyData(device.runtimeID, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value), device.runtimeID, property.mSelector)
        return try scalar(device.runtimeID, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))
    }
    /// Runtime monitoring still enumerates identities (including duplicate UIDs),
    /// but only probes capabilities for the explicitly selected endpoints.
    public static func snapshot(selectedUIDs: Set<String>? = nil) throws -> CatalogSnapshot {
        let ids: [UInt32] = try values(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        var devices: [DeviceFacts] = []
        var issues: [String] = []
        for id in ids {
            do {
                if let selectedUIDs, !selectedUIDs.contains(try string(id, kAudioDevicePropertyDeviceUID)) { continue }
                devices.append(try device(id))
            }
            catch { issues.append("Device \(id): \(error)") }
        }
        // Duplicate UIDs cannot safely represent an explicit endpoint selection.
        let groups = Dictionary(grouping: devices, by: \.uid)
        let duplicates = Set(groups.filter { $0.value.count > 1 }.map(\.key))
        issues += duplicates.sorted().map { "Duplicate UID excluded: \($0)" }
        return CatalogSnapshot(devices: devices.filter { !duplicates.contains($0.uid) }
            .sorted { ($0.name, $0.uid) < ($1.name, $1.uid) }, issues: issues)
    }

    private static func device(_ id: UInt32) throws -> DeviceFacts {
        let uid = try string(id, kAudioDevicePropertyDeviceUID)
        guard !uid.isEmpty else { throw ProbeError.invalid("Empty device UID") }
        var issues: [String] = []
        func read<T>(_ label: String, _ body: () throws -> T) -> T? {
            do { return try body() } catch { issues.append("\(label): \(error)"); return nil }
        }
        let name = read("name") { try string(id, kAudioObjectPropertyName) } ?? "Unnamed device (\(id))"
        let transport = read("transport") { fourCC(try scalar(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) }
        let alive = read("alive") { try scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1 }
        let rate = read("nominal sample rate") { try scalar(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) }
        let rates: [ValueRange] = read("available sample rates") {
            let ranges: [AudioValueRange] = try values(id, kAudioDevicePropertyAvailableNominalSampleRates)
            return ranges.map(range)
        } ?? []
        let frames = read("buffer frames") { try scalar(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) }
        let frameRange = read("buffer range") { range(try scalar(id, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange())) }
        let clock = read("clock domain") { try scalar(id, kAudioDevicePropertyClockDomain, initial: UInt32(0)) }
        let input = direction(id, scope: kAudioObjectPropertyScopeInput, issues: &issues)
        let output = direction(id, scope: kAudioObjectPropertyScopeOutput, issues: &issues)
        return DeviceFacts(runtimeID: id, uid: uid, name: name, transport: transport, iconURL: iconURL(id), alive: alive,
            nominalSampleRate: rate, availableSampleRates: rates, bufferFrames: frames,
            bufferFrameRange: frameRange, clockDomain: clock, input: input, output: output, issues: issues)
    }

    private static func direction(_ id: UInt32, scope: UInt32, issues: inout [String]) -> DirectionFacts {
        let label = scope == kAudioObjectPropertyScopeInput ? "input" : "output"
        func read<T>(_ property: String, _ body: () throws -> T) -> T? {
            do { return try body() } catch { issues.append("\(label) \(property): \(error)"); return nil }
        }
        let channels = read("stream configuration") { () throws -> [UInt32] in
            try bytes(id, kAudioDevicePropertyStreamConfiguration, scope: scope) { pointer, size in
                let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
                guard size >= offset else { throw ProbeError.invalid("Truncated AudioBufferList") }
                let count = Int(pointer.load(as: UInt32.self))
                guard count <= (size - offset) / MemoryLayout<AudioBuffer>.stride else {
                    throw ProbeError.invalid("Invalid AudioBufferList length")
                }
                return (0..<count).map {
                    pointer.load(fromByteOffset: offset + $0 * MemoryLayout<AudioBuffer>.stride, as: AudioBuffer.self).mNumberChannels
                }
            }
        }
        let streamIDs: [UInt32] = read("streams") { try values(id, kAudioDevicePropertyStreams, scope: scope) } ?? []
        var layoutTag: UInt32?
        var labels: [UInt32] = []
        if let channels, !channels.isEmpty {
            if let layout = read("preferred channel layout", {
                try bytes(id, kAudioDevicePropertyPreferredChannelLayout, scope: scope) { pointer, size -> (UInt32, [UInt32]) in
                    let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
                    guard size >= offset else { throw ProbeError.invalid("Truncated channel layout") }
                    let tag = pointer.load(as: UInt32.self)
                    let count = Int(pointer.load(fromByteOffset: 8, as: UInt32.self))
                    guard count <= (size - offset) / MemoryLayout<AudioChannelDescription>.stride else {
                        throw ProbeError.invalid("Invalid channel layout length")
                    }
                    let labels = (0..<count).map {
                        pointer.load(fromByteOffset: offset + $0 * MemoryLayout<AudioChannelDescription>.stride,
                                     as: AudioChannelDescription.self).mChannelLabel
                    }
                    return (tag, labels)
                }
            }) { layoutTag = layout.0; labels = layout.1 }
        }
        let streams = streamIDs.map { streamID -> StreamFacts in
            func streamRead<T>(_ property: String, _ body: () throws -> T) -> T? {
                do { return try body() } catch { issues.append("\(label) stream \(streamID) \(property): \(error)"); return nil }
            }
            let start = streamRead("starting channel") { try scalar(streamID, kAudioStreamPropertyStartingChannel, initial: UInt32(0)) }
            let virtual = streamRead("virtual format") { format(try scalar(streamID, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())) }
            let physical = streamRead("physical format") { format(try scalar(streamID, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())) }
            let virtualFormats: [RangedStreamFormat] = streamRead("available virtual formats") {
                let list: [AudioStreamRangedDescription] = try values(streamID, kAudioStreamPropertyAvailableVirtualFormats)
                return list.map { RangedStreamFormat(format: format($0.mFormat), sampleRates: range($0.mSampleRateRange)) }
            } ?? []
            let physicalFormats: [RangedStreamFormat] = streamRead("available physical formats") {
                let list: [AudioStreamRangedDescription] = try values(streamID, kAudioStreamPropertyAvailablePhysicalFormats)
                return list.map { RangedStreamFormat(format: format($0.mFormat), sampleRates: range($0.mSampleRateRange)) }
            } ?? []
            return StreamFacts(runtimeID: streamID, startingChannel: start, virtualFormat: virtual,
                physicalFormat: physical, availableVirtualFormats: virtualFormats, availablePhysicalFormats: physicalFormats,
                latencyFrames: streamRead("latency") { try scalar(streamID, kAudioStreamPropertyLatency, initial: UInt32(0)) })
        }
        return DirectionFacts(channelCount: channels.map { $0.reduce(0) { $0 + Int($1) } },
            bufferChannelCounts: channels ?? [], preferredLayoutTag: layoutTag, channelLabels: labels, streams: streams,
            latencyFrames: channels?.isEmpty == false ? read("latency", { try scalar(id, kAudioDevicePropertyLatency, initial: UInt32(0), scope: scope) }) : nil,
            safetyOffsetFrames: channels?.isEmpty == false ? read("safety offset", { try scalar(id, kAudioDevicePropertySafetyOffset, initial: UInt32(0), scope: scope) }) : nil)
    }

    private static func address(_ selector: UInt32, _ scope: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    // Private generic helpers are called only with POD types from the SDK, never Swift references.
    private static func scalar<T>(_ id: UInt32, _ selector: UInt32, initial: T, scope: UInt32 = kAudioObjectPropertyScopeGlobal) throws -> T {
        var property = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
        }
        try check(status, id, selector)
        guard size == MemoryLayout<T>.size else { throw ProbeError.invalid("Unexpected scalar size") }
        return value
    }
    private static func scalarValue(_ id: UInt32, _ selector: UInt32, scope: UInt32) throws -> Float {
        let value: Float = try scalar(id, selector, initial: Float(0), scope: scope)
        guard value.isFinite, (0...1).contains(value) else { throw ProbeError.invalid("Output volume readback is outside the documented scalar range.") }
        return value
    }
    private static func string(_ id: UInt32, _ selector: UInt32) throws -> String {
        var property = address(selector, kAudioObjectPropertyScopeGlobal)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &result)
        try check(status, id, selector)
        guard size == MemoryLayout<Unmanaged<CFString>?>.size, let result else {
            throw ProbeError.invalid("Missing CFString")
        }
        // HAL name/UID properties transfer ownership to the caller (AudioHardwareBase.h).
        return result.takeRetainedValue() as String
    }
    private static func iconURL(_ id: UInt32) -> URL? {
        var property = address(kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal)
        guard AudioObjectHasProperty(id, &property) else { return nil }
        var result: Unmanaged<CFURL>?
        var size = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &result)
        guard status == noErr, let result else { return nil }
        // This property transfers CFURL ownership to the caller, like name/UID.
        let url = result.takeRetainedValue() as URL
        guard size == MemoryLayout<Unmanaged<CFURL>?>.size, url.isFileURL else { return nil }
        return url
    }
    private static func values<T>(_ id: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        try bytes(id, selector, scope: scope) { pointer, size in
            guard size % MemoryLayout<T>.stride == 0 else { throw ProbeError.invalid("Misaligned property array") }
            return (0..<(size / MemoryLayout<T>.stride)).map {
                pointer.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self)
            }
        }
    }
    private static func bytes<T>(_ id: UInt32, _ selector: UInt32, scope: UInt32, body: (UnsafeMutableRawPointer, Int) throws -> T) throws -> T {
        var property = address(selector, scope)
        var capacity: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &capacity), id, selector)
        guard capacity <= 16 * 1024 * 1024 else { throw ProbeError.invalid("Property size exceeds safety limit") }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(1, Int(capacity)), alignment: 16)
        defer { pointer.deallocate() }
        var size = capacity
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer), id, selector)
        guard size <= capacity else { throw ProbeError.invalid("Property grew during read") }
        return try body(pointer, Int(size))
    }
    private static func check(_ status: OSStatus, _ id: UInt32, _ selector: UInt32) throws {
        guard status == noErr else { throw ProbeError.hal(id, fourCC(selector), status) }
    }
    private static func range(_ value: AudioValueRange) -> ValueRange {
        ValueRange(minimum: value.mMinimum, maximum: value.mMaximum)
    }
    private static func format(_ value: AudioStreamBasicDescription) -> StreamFormat {
        StreamFormat(formatID: fourCC(value.mFormatID), sampleRate: value.mSampleRate,
            channels: value.mChannelsPerFrame, bitsPerChannel: value.mBitsPerChannel,
            bytesPerFrame: value.mBytesPerFrame, bytesPerPacket: value.mBytesPerPacket,
            framesPerPacket: value.mFramesPerPacket, flags: value.mFormatFlags,
            isPCM: value.mFormatID == kAudioFormatLinearPCM,
            isFloat: value.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            isSignedInteger: value.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
            isNonInterleaved: value.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
            isBigEndian: value.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
            isPacked: value.mFormatFlags & kAudioFormatFlagIsPacked != 0)
    }
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = (0..<4).map { UInt8((value >> (24 - $0 * 8)) & 0xff) }
        return bytes.allSatisfy { (32...126).contains($0) }
            ? String(bytes: bytes, encoding: .ascii)! : String(format: "0x%08x", value)
    }
    public enum ProbeError: Error, CustomStringConvertible {
        case hal(UInt32, String, OSStatus)
        case invalid(String)
        public var description: String {
            switch self {
            case let .hal(id, selector, status): return "HAL object \(id), property \(selector), OSStatus \(status)"
            case let .invalid(reason): return reason
            }
        }
    }
}
