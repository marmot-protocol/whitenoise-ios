import SwiftUI
import MarmotKit

/// One chat bubble. Aligned right for our own messages, left for everyone
/// else; uses a gradient for outgoing messages and the system secondary
/// background for incoming ones (matches Messages.app under Liquid Glass).
/// A small caption under each bubble shows the time and, for our messages,
/// the delivery state.
struct MessageBubble: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass
    let record: AppMessageRecordFfi
    let status: MessageStatus

    private var isFromMe: Bool { record.direction == "sent" }

    /// Near-full-width on iPhone (compact); capped on iPad (regular) so bubbles
    /// don't stretch the whole window.
    private var bubbleMaxWidth: CGFloat? {
        sizeClass == .regular ? 560 : nil
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isFromMe { Spacer(minLength: 48) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                if !isFromMe {
                    Text(appState.displayName(forAccountIdHex: record.sender))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                Text(ProfileSanitizer.messageBody(record.plaintext))
                    .font(.body)
                    .foregroundStyle(isFromMe ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .clipShape(.rect(cornerRadius: 18))
                    .textSelection(.enabled)
                    .opacity(status == .sending ? 0.7 : 1)

                metaLine
                    .padding(isFromMe ? .trailing : .leading, 12)
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: isFromMe ? .trailing : .leading)

            if !isFromMe { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
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
