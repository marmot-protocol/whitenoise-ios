import SwiftUI
import MarmotKit

/// Question, options with live tallies, and voting for one poll bubble.
struct PollMessageContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let poll: PollProjectionFfi
    let isFromMe: Bool
    /// Nil when the viewer cannot vote here (inactive group, pending row).
    let onVote: ((String) -> Void)?
    /// Opens the per-voter results sheet.
    var onViewVotes: (() -> Void)? = nil

    private var foreground: Color { MessageBubblePalette.foreground(isFromMe: isFromMe) }
    private var secondaryForeground: Color { MessageBubblePalette.secondaryForeground(isFromMe: isFromMe) }

    /// Redraws once at the deadline so an on-screen poll closes on time.
    private var deadlineSchedule: [Date] {
        PollPresentation.deadlineRefresh(for: poll, now: .now).map { [$0] } ?? []
    }

    var body: some View {
        // The context date can be a future schedule entry, so read the real clock.
        TimelineView(.explicit(deadlineSchedule)) { _ in
            content(isOpen: PollPresentation.isOpen(poll, now: .now))
        }
    }

    private func content(isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.subheadline)
                    .foregroundStyle(secondaryForeground)
                    .accessibilityLabel(L10n.string("Poll"))
                Text(ContentSanitizer.messageBody(poll.question))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 0) {
                ForEach(poll.options, id: \.id) { option in
                    optionRow(option, isOpen: isOpen)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(PollPresentation.footerText(for: poll, isOpen: isOpen))
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)

                if let onViewVotes, PollPresentation.offersVoteList(poll) {
                    Button(action: onViewVotes) {
                        Label(L10n.string("View votes"), systemImage: "person.2")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(foreground)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(MessageBubbleReplyLayout.cardOuterInset)
    }

    private func optionRow(_ option: PollOptionResultFfi, isOpen: Bool) -> some View {
        let selected = poll.localSelection.contains(option.id)
        let fraction = PollPresentation.fraction(votes: option.votes, participants: poll.participants)
        return Button {
            onVote?(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
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
                resultBar(fraction: fraction)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(onVote == nil || !isOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ContentSanitizer.messageBody(option.label))
        .accessibilityValue(L10n.plural("%lld votes", Int64(clamping: option.votes)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func resultBar(fraction: Double) -> some View {
        let scale: CGFloat = 2.5
        let trackScheme: ColorScheme = isFromMe ? (colorScheme == .light ? .dark : .light) : colorScheme
        return GeometryReader { bounds in
            // Scale both axes to keep the native bar’s ends round at the larger size.
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.primary)
                .environment(\.colorScheme, trackScheme)
                .frame(width: bounds.size.width / scale)
                .scaleEffect(scale, anchor: .leading)
                .frame(height: bounds.size.height)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: fraction)
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
