import AudioBridgeStrings
import AppKit
import AudioBridgeCore
import SwiftUI

extension AppModel {
    var activity: RoutingActivity {
        if recovery.desired && !routingRequested && !recovery.blocked && error == nil && routingFault == nil { return .starting }
        let s = engineSnapshot
        return RoutingActivity.resolve(fault: routingFault != nil || error != nil,
            requested: routingRequested, transitioning: routingTransitioning,
            configured: !stoppedByUser && selection.input.uid != nil && selection.output.uid != nil,
            configurationFault: inputIssue != nil || outputIssue != nil || permission != "Granted" || routeReadiness != nil,
            primed: s?.primed == true, callbacksFresh: s?.inputActive == true && s?.outputActive == true,
            deliveredFrames: (s?.outputFrames ?? 0) > 0, buffered: s?.primed == true,
            glitches: s?.recentGlitches == true)
    }
}

@MainActor
enum MenuStatusIcon {
    static func color(_ activity: RoutingActivity) -> Color {
        switch activity { case .idle: return .secondary; case .running: return .green
        case .starting, .degraded: return .orange; case .actionRequired: return .red }
    }
    private static let images: [RoutingActivity: NSImage] = Dictionary(uniqueKeysWithValues: RoutingActivity.allCases.map { activity in
        let colour: NSColor
        switch activity { case .idle: colour = .secondaryLabelColor; case .running: colour = .systemGreen
        case .starting, .degraded: colour = .systemOrange; case .actionRequired: colour = .systemRed }
        let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Audio Bridge")
        let result = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            symbol?.draw(in: rect.insetBy(dx: 1, dy: 1))
            colour.setFill(); rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return (activity, result)
    })
    static func image(_ activity: RoutingActivity) -> NSImage { images[activity]! }
}

struct RoutingStatusLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Label {
            Text(LT(model.status))
        } icon: {
            Image(systemName: model.activity == .actionRequired ? "exclamationmark.circle.fill" : "circle.fill")
                .foregroundStyle(MenuStatusIcon.color(model.activity))
        }.accessibilityElement(children: .combine)
    }
}
