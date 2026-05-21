import SwiftUI
import MarmotKit

/// One chat bubble. Aligned right for our own messages, left for everyone
/// else. Renders an optional quoted reply header, the message body, a
/// time/delivery caption, and any reaction chips.
struct MessageBubble: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass
    let record: AppMessageRecordFfi
    let status: MessageStatus
    var isDeleted: Bool = false
    var replyPreview: (name: String, text: String)? = nil
    var reactions: [ConversationViewModel.ReactionTally] = []
    var onTapReaction: (String) -> Void = { _ in }

    private var isFromMe: Bool { record.direction == "sent" }

    private var bubbleMaxWidth: CGFloat? {
        sizeClass == .regular ? 560 : nil
    }

    /// Minimum gap on the opposite side. Tiny on iPhone so long bubbles run
    /// (near) full width; larger on iPad where width is also capped above.
    private var oppositeInset: CGFloat {
        sizeClass == .regular ? 64 : 0
    }

    /// Reply text lives in the structured payload; plain messages use plaintext.
    private var bodyText: String {
        if case .reply(_, let text)? = record.appMessage { return text }
        return record.plaintext
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isFromMe { Spacer(minLength: oppositeInset) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                if !isFromMe {
                    Text(appState.displayName(forAccountIdHex: record.sender))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                if isDeleted {
                    deletedBubble
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if let replyPreview {
                            quoted(replyPreview)
                        }
                        Text(ProfileSanitizer.messageBody(bodyText))
                            .foregroundStyle(isFromMe ? Color.white : Color.primary)
                    }
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .clipShape(.rect(cornerRadius: 18))
                    // No .textSelection here: it installs its own long-press
                    // recognizer that swallows the bubble's long-press (the
                    // actions menu). Copy is offered in the actions sheet.
                    .opacity(status == .sending ? 0.7 : 1)

                    if !reactions.isEmpty {
                        reactionChips
                    }
                }

                metaLine
                    .padding(isFromMe ? .trailing : .leading, 12)
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: isFromMe ? .trailing : .leading)

            if !isFromMe { Spacer(minLength: oppositeInset) }
        }
        .padding(.horizontal, 12)
    }

    private var deletedBubble: some View {
        HStack(spacing: 5) {
            Image(systemName: "trash")
            Text("This message was deleted")
        }
        .font(.callout)
        .italic()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    private func quoted(_ preview: (name: String, text: String)) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(isFromMe ? Color.white.opacity(0.8) : Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.name)
                    .font(.caption.weight(.semibold))
                Text(preview.text)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isFromMe ? Color.white.opacity(0.9) : Color.secondary)
            Spacer(minLength: 0)
        }
        // Without this the width-only Capsule is greedy vertically and stretches
        // the whole bubble; fixedSize pins the quote to its content height.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 1)
    }

    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { tally in
                Button {
                    onTapReaction(tally.emoji)
                } label: {
                    HStack(spacing: 2) {
                        Text(tally.emoji)
                        if tally.count > 1 {
                            Text("\(tally.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(tally.mine ? Color.accentColor.opacity(0.22) : Color(.tertiarySystemFill))
                    )
                    .overlay(
                        Capsule().stroke(tally.mine ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .padding(isFromMe ? .trailing : .leading, 8)
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(timeLabel)
            if isFromMe, let statusLabel {
                Text("·")
                Text(statusLabel)
            }
        }
        .font(.caption2)
        .foregroundStyle(status == .failed ? Color.red : Color.secondary)
    }

    private var timeLabel: String {
        let date = Date(timeIntervalSince1970: TimeInterval(record.recordedAt))
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private var statusLabel: String? {
        switch status {
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .failed: return "Not delivered"
        case .received: return nil
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isFromMe {
            LinearGradient(
                colors: [.blue, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(.secondarySystemBackground)
        }
    }
}
