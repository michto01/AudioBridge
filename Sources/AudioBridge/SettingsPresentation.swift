import AudioBridgeStrings
import SwiftUI

/// One consistent home for each group's explanatory text.
struct InfoGroupBox<Content: View>: View {
    let title: String
    let message: String
    let content: Content

    init(_ title: String, message: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.message = message
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
        } label: {
            HStack {
                Text(LT(title)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                InfoButton(title: title, message: message)
            }
        }
    }
}

struct SettingsGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1) }
    }
}

struct ReadoutRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(LT(title)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(LT(value)).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Measure both endpoint cards before placing them. Both get the taller intrinsic
/// height at the same column width, with no persisted or arbitrary height floor.
struct BridgeEndpointLayout: Layout {
    private let arrowWidth: CGFloat = 24
    private let spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = proposal.width ?? 760
        let column = max(0, (width - arrowWidth - spacing * 2) / 2)
        let cardProposal = ProposedViewSize(width: column, height: nil)
        let height = max(subviews[0].sizeThatFits(cardProposal).height,
                         subviews[2].sizeThatFits(cardProposal).height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let column = max(0, (bounds.width - arrowWidth - spacing * 2) / 2)
        let cardProposal = ProposedViewSize(width: column, height: bounds.height)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: cardProposal)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: arrowWidth, height: arrowWidth))
        subviews[2].place(at: CGPoint(x: bounds.maxX - column, y: bounds.minY),
                          anchor: .topLeading, proposal: cardProposal)
    }
}
