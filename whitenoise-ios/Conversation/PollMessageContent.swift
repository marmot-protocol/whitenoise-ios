import SwiftUI
import MarmotKit

/// Question, options with live tallies, and voting for one poll bubble.
struct PollMessageContent: View {
    let poll: PollProjectionFfi
    let isFromMe: Bool
    /// Nil when the viewer cannot vote here (inactive group, pending row).
    let onVote: ((String) -> Void)?

    private var isOpen: Bool { PollPresentation.isOpen(poll, now: .now) }
    private var isMultipleChoice: Bool { poll.pollType == .multipleChoice }
    private var foreground: Color { MessageBubblePalette.foreground(isFromMe: isFromMe) }
    private var secondaryForeground: Color { MessageBubblePalette.secondaryForeground(isFromMe: isFromMe) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ContentSanitizer.messageBody(poll.question))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    isMultipleChoice ? L10n.string("Poll · Select one or more") : L10n.string("Poll · Select one"),
                    systemImage: "chart.bar.xaxis"
                )
                .font(.caption)
                .foregroundStyle(secondaryForeground)
            }

            ForEach(poll.options, id: \.id) { option in
                optionRow(option)
            }

            Text(footerText)
                .font(.caption)
                .foregroundStyle(secondaryForeground)
        }
        .padding(.horizontal, ChatBubbleMetrics.horizontalInset)
        .padding(.vertical, 12)
        .frame(width: MessageBubbleReplyLayout.richContentWidth, alignment: .leading)
    }

    private func optionRow(_ option: PollOptionResultFfi) -> some View {
        let selected = poll.localSelection.contains(option.id)
        let fraction = PollPresentation.fraction(votes: option.votes, participants: poll.participants)
        return Button {
            onVote?(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(selected: selected))
                        .foregroundStyle(selected ? foreground : secondaryForeground)
                        .accessibilityHidden(true)
                    Text(ContentSanitizer.messageBody(option.label))
                        .foregroundStyle(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(option.votes, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(secondaryForeground)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                Capsule()
                    .fill(secondaryForeground.opacity(0.25))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(foreground)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(onVote == nil || !isOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ContentSanitizer.messageBody(option.label))
        .accessibilityValue(L10n.plural("%lld votes", Int64(clamping: option.votes)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func symbol(selected: Bool) -> String {
        switch (isMultipleChoice, selected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "checkmark.circle.fill"
        case (false, false): "circle"
        }
    }

    private var footerText: String {
        let votes = L10n.plural("%lld votes", Int64(clamping: poll.participants))
        if !isOpen {
            return "\(votes) · \(L10n.string("Final results"))"
        }
        if let endsAt = poll.endsAt {
            let date = Date(timeIntervalSince1970: TimeInterval(endsAt))
            let ends = L10n.formatted("Ends %@", date.formatted(date: .abbreviated, time: .shortened))
            return "\(votes) · \(ends)"
        }
        return votes
    }
}
