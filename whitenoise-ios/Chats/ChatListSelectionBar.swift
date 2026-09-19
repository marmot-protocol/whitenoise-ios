import SwiftUI

struct ChatListSelectionBar<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let count: Int
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 12) { layout }
            } else {
                layout
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var layout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedLayout
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    leading.frame(maxWidth: .infinity, alignment: .leading)
                    selectionCount.fixedSize()
                    trailing.frame(maxWidth: .infinity, alignment: .trailing)
                }
                stackedLayout
            }
        }
    }

    private var stackedLayout: some View {
        VStack(spacing: 12) {
            selectionCount
            HStack {
                leading
                Spacer(minLength: 12)
                trailing
            }
        }
    }

    private var selectionCount: some View {
        Text(L10n.plural("%lld selected", Int64(count)))
            .font(.body.weight(.medium))
            .contentTransition(.numericText())
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .wnLiftedChrome(in: .capsule)
            .accessibilityIdentifier("chats.selection.count")
    }
}
