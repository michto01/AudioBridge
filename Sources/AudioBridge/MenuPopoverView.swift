import AppKit
import AudioBridgeCore
import AudioBridgeStrings
import SwiftUI

/// A compact monitoring surface. Configuration and digital trims stay in Settings.
struct MenuPopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            header
            Divider()
            VStack(spacing: 6) {
                MenuEndpointCard(model: model, direction: .input)
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MenuStatusIcon.color(model.activity))
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
                    .accessibilityLabel(L("routes to"))
                MenuEndpointCard(model: model, direction: .output)
            }
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(width: 32)
                OutputDeviceVolumeControl(model: model, allowsDigitalFallback: false, compactLabel: true)
            }
            Divider()
            HStack(spacing: 10) {
                RoutingToggleButton(model: model, fillsWidth: true)
                SettingsLink {
                    Label(L("Settings…"), systemImage: "gearshape.fill")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(FocusedSettingsLinkStyle())
                Button { model.quit() } label: {
                    Label(L("Quit"), systemImage: "xmark")
                }.buttonStyle(.bordered)
                    .accessibilityLabel(L("Quit")).help(L("Quit"))
            }.controlSize(.large)
        }
        .padding(18)
        .frame(width: 440)
        // MenuBarExtra supplies the material and outer corners. Painting another
        // rounded surface here exposes the native panel behind its corners.
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit().frame(width: 54, height: 54)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Audio Bridge")).font(.title2.weight(.bold))
                Text(L("Audio routing for macOS"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: model.activity == .actionRequired ? "exclamationmark.circle.fill" : "circle.fill")
                        .foregroundStyle(MenuStatusIcon.color(model.activity))
                    Text(LT(statusTitle)).font(.headline)
                    InfoButton(title: L("Bridge status"), message: model.bridgeStatusHelp)
                }
                if model.routingRequested, let started = model.routingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(context.date.timeIntervalSince(started)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityLabel(L("Running for \(elapsed(context.date.timeIntervalSince(started)))"))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch model.activity {
        case .running: return "Running"
        case .starting: return "Starting…"
        case .degraded: return "Warning"
        case .actionRequired: return "Needs attention"
        case .idle: return "Stopped"
        }
    }
    private func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

/// Use the macOS 14 SettingsLink action while keeping activation and focus
/// identical for mouse and keyboard activation. No newer environment API needed.
private struct FocusedSettingsLinkStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            SettingsWindowFocus.show { configuration.trigger() }
        } label: {
            configuration.label
        }.buttonStyle(.bordered)
    }
}

private struct MenuEndpointCard: View {
    @ObservedObject var model: AppModel
    let direction: AudioDirection
    private var device: DeviceFacts? { model.device(direction) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let device {
                        DeviceIcon(device: device, direction: direction, image: model.deviceIcons[device.uid], size: 30)
                    } else {
                        Image(systemName: direction == .input ? "mic" : "speaker.wave.2")
                            .resizable().scaledToFit().frame(width: 30, height: 30)
                    }
                }
                .frame(width: 50, height: 50)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT(direction == .input ? "Input device" : "Output device"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(device?.name ?? LT(model.endpoint(direction).uid == nil ? "Unconfigured" : "Selected device missing"))
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        .frame(height: 38, alignment: .leading)
                        .help(device?.name ?? L("Device not connected"))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            SignalMeters(model: model, direction: direction, compact: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
