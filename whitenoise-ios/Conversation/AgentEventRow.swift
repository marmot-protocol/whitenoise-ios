import SwiftUI
import MarmotKit

/// Subtle inline row for agent activity (1201) and operation (1202) events.
struct AgentEventRow: View {
    let senderName: String
    let display: AgentEventPresentation.Display
    var debugStyle: MessageDebugStyle? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(senderName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Image(systemName: display.iconName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 4)

                Text(display.primaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic(display.kind == .activity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)

                if let secondary = display.secondaryText {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }

                if let debugStyle {
                    debugDetail(debugStyle)
                        .padding(.leading, 4)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func debugDetail(_ style: MessageDebugStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(style.kindLabel)
                .font(.caption2.monospaced())
            if !style.tagsSummary.isEmpty {
                Text(style.tagsSummary)
                    .font(.caption2.monospaced())
            }
        }
        .foregroundStyle(style.category.accentColor.opacity(0.85))
        .padding(.top, 4)
    }
}
