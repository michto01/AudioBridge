import AudioBridgeCore
import CoreAudio
import Foundation

/// Owns exactly the block/address/queue pairs required for listener removal.
/// Property events only enqueue refresh; this class is never used for audio IO callbacks.
public final class CatalogObservation {
    private struct Registration {
        let id: UInt32
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var registrations: [Registration] = []
    private let changed: () -> Void
    public private(set) var issues: [String] = []
    public init(changed: @escaping () -> Void) { self.changed = changed }

    public func watch(_ devices: [DeviceFacts]) {
        removeAll()
        issues = []
        add(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        for device in devices {
            for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
                             kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyBufferFrameSize,
                             kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyName] {
                add(device.runtimeID, selector)
            }
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                for selector in [kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration] {
                    add(device.runtimeID, selector, scope: scope)
                }
            }
            for stream in device.input.streams + device.output.streams {
                for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat,
                                 kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats,
                                 kAudioStreamPropertyStartingChannel] {
                    add(stream.runtimeID, selector)
                }
            }
        }
    }
    private func add(_ id: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return }
        let changed = self.changed
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Always enqueue, even if HAL invokes a listener outside the requested queue.
            DispatchQueue.main.async(execute: changed)
        }
        let status = AudioObjectAddPropertyListenerBlock(id, &address, .main, block)
        if status == noErr { registrations.append(Registration(id: id, address: address, block: block)) }
        else { issues.append("Listener object \(id), selector \(selector): OSStatus \(status)") }
    }
    private func removeAll() {
        for var registration in registrations {
            // A removed device may no longer exist. Blocks capture no raw client-data pointers.
            _ = AudioObjectRemovePropertyListenerBlock(registration.id, &registration.address, .main, registration.block)
        }
        registrations.removeAll()
    }
    deinit { removeAll() }
}
