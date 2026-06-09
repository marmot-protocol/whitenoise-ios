import SwiftUI
import MarmotKit

/// One row in the chats list. Renders 2-member groups in "DM" style (other
/// member's identity in place of group name) and N>2 groups by group name.
/// The subtitle previews the latest message; the trailing label is its
/// relative timestamp.
struct ChatRow: View {
    @Environment(AppState.self) private var appState
    let item: ChatsListViewModel.Item

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: item.id,
                title: title,
                pictureURL: item.avatarURL
            )
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(item.hasUnread ? .headline.weight(.semibold) : .headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .fontWeight(item.hasUnread ? .semibold : .regular)
                    .foregroundStyle(item.hasUnread ? .primary : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if let timestamp {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(item.hasUnread ? Color.accentColor : .secondary)
                        .fontWeight(item.hasUnread ? .semibold : .regular)
                        .monospacedDigit()
                }
                if item.hasUnread {
                    Text(unreadBadgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel("\(item.unreadCount) unread messages")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        item.title
    }

    /// Latest message preview. Sent messages are prefixed with "You:".
    private var subtitle: String {
        guard let latest = item.lastMessage else {
            return L10n.string("No messages yet")
        }
        let body = ProfileSanitizer.singleLine(MessagePreview.body(latest), maxLength: 140) ?? ""
        if latest.sender == appState.activeAccount?.accountIdHex {
            return body.isEmpty ? L10n.string("You sent a message") : L10n.string("You: \(body)")
        }
        return body.isEmpty ? L10n.string("New message") : body
    }

    private var timestamp: String? {
        guard let latest = item.lastMessage else { return nil }
        return RelativeTime.short(Date(timeIntervalSince1970: TimeInterval(latest.timelineAt)))
    }

    private var unreadBadgeText: String {
        item.unreadCount > 99 ? "99+" : "\(item.unreadCount)"
    }
}

/// Circular avatar. Renders the profile picture when a URL is provided,
/// otherwise falls back to initials over a deterministic color derived from
/// the seed string (so a given group/person keeps the same color).
struct AvatarBubble: View {
    let seed: String
    let title: String
    var pictureURL: URL? = nil

    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [color.opacity(0.85), color.opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                if let pictureURL {
                    AsyncImage(url: pictureURL) { phase in
                        switch phase {
                        case .success(let image):
                            // Fill the circle edge-to-edge, aspect-preserved
                            // and center-cropped. The overlay sizes the image
                            // to the circle's bounds; clipShape crops overflow.
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty, .failure:
                            initialsView
                        @unknown default:
                            initialsView
                        }
                    }
                } else {
                    initialsView
                }
            }
            .clipShape(Circle())
    }

    private var initialsView: some View {
        Text(initials)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initials: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let first = parts.first?.first.map(String.init) ?? ""
        let second = parts.count > 1 ? (parts[1].first.map(String.init) ?? "") : ""
        let combined = (first + second).uppercased()
        return combined.isEmpty ? "?" : combined
    }

    private var color: Color {
        let palette: [Color] = [.indigo, .blue, .teal, .green, .orange, .pink, .purple, .red]
        let hash = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}
