import SwiftUI
import MarmotKit

/// Inline metadata for agent operations. Activity updates use a message bubble.
struct AgentEventRow: View {
    let senderName: String
    let display: AgentEventPresentation.Display
    var debugStyle: MessageDebugStyle? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(senderName)
                    Image(systemName: display.iconName)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                Text(display.primaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let secondary = display.secondaryText {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let debugStyle {
                    debugDetail(debugStyle)
                }
            }
            .padding(.leading, 4)
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

struct AgentActivityContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let display: AgentEventPresentation.Display

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TimelineSearchText(display.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if display.iconName == "ellipsis.message" {
                        Image(systemName: display.iconName)
                            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: display.reportsWorkInProgress && !reduceMotion)
                    } else {
                        Image(systemName: display.iconName)
                            .symbolEffect(.pulse, options: .repeat(.continuous), isActive: display.reportsWorkInProgress && !reduceMotion)
                    }
                }
                .accessibilityHidden(true)
            }
            if let status = display.visibleActivityStatus {
                TimelineSearchText(status)
                    .font(.caption)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityValue(display.showsStatusInIcon ? display.secondaryText ?? "" : "")
    }

}
