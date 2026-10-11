import AudioBridgeCore
import AppKit
import SwiftUI

/// Prefer the device/driver-provided Core Audio icon; use a native class symbol otherwise.
struct DeviceIcon: View {
    let device: DeviceFacts
    let direction: AudioDirection
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol).resizable().scaledToFit()
            }
        }
        .frame(width: NSFont.systemFontSize, height: NSFont.systemFontSize)
        .clipped()
        .accessibilityHidden(true)
    }
    private var fallbackSymbol: String {
        switch device.transport {
        case "grup": return "square.stack.3d.up"
        case "virt": return "waveform"
        case "usb ": return "cable.connector"
        case "thun": return "bolt"
        case "ccwd", "ccwl": return "iphone"
        default: return direction == .input ? "mic" : "speaker.wave.2"
        }
    }
}
