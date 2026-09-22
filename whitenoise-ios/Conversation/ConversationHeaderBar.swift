import SwiftUI

enum ConversationHeaderMetrics {
    static let controlGap: CGFloat = 16
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 6

    /// Room the centered title gives up on *both* sides, so it stays on the
    /// bar's midline whichever single control is showing and truncates before
    /// it can reach one.
    static func titleInset(controlDiameter: CGFloat) -> CGFloat {
        controlDiameter + controlGap
    }
}

/// The conversation's in-content top bar: edge controls with the identity
/// cluster on the bar's own midline, the way a navigation bar centers a
/// principal item rather than butting it against the back chevron.
struct ConversationHeaderBar<Title: View>: View {
    let isSelectingMessages: Bool
    let onBack: () -> Void
    let onClose: () -> Void
    @ViewBuilder var title: Title

    @ScaledMetric(relativeTo: .body)
    private var controlDiameter = WNSecondaryButtonStyle.Metrics.circleDiameter

    var body: some View {
        ZStack {
            title
                .padding(
                    .horizontal,
                    ConversationHeaderMetrics.titleInset(controlDiameter: controlDiameter)
                )

            // Above the title in z-order: wherever the two still meet, the
            // control keeps the tap.
            HStack(spacing: ConversationHeaderMetrics.controlGap) {
                // Selection owns the header; its only exit is the close button.
                if !isSelectingMessages {
                    WNIconButton(title: "Back", systemImage: "chevron.backward", action: onBack)
                }

                Spacer(minLength: 0)

                if isSelectingMessages {
                    WNIconButton(title: "Close", systemImage: "xmark", action: onClose)
                }
            }
        }
        .padding(.horizontal, ConversationHeaderMetrics.horizontalPadding)
        .padding(.vertical, ConversationHeaderMetrics.verticalPadding)
        .frame(maxWidth: .infinity)
        .wnFadingHeader()
    }
}
