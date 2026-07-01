import SwiftUI
import MarmotKit
import UIKit

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
                    UnreadCountBadge(count: item.unreadCount)
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
        Self.subtitleText(for: item, activeAccountIdHex: appState.activeAccount?.accountIdHex)
    }

    static func subtitleText(
        for item: ChatsListViewModel.Item,
        activeAccountIdHex: String?
    ) -> String {
        guard let latest = item.lastMessage else {
            return L10n.string("No messages yet")
        }
        let body = item.previewText ?? ""
        if latest.sender == activeAccountIdHex {
            return body.isEmpty ? L10n.string("You sent a message") : L10n.formatted("You: %@", body)
        }
        return body.isEmpty ? L10n.string("New message") : body
    }

    private var timestamp: String? {
        guard let latest = item.lastMessage else { return nil }
        return RelativeTime.short(Date(timeIntervalSince1970: TimeInterval(latest.timelineAt)))
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
                initialsView
                if let pictureURL {
                    AvatarRemoteImage(url: pictureURL)
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
        return palette[Self.paletteIndex(forHash: hash, paletteCount: palette.count)]
    }

    static func paletteIndex(forHash hash: Int, paletteCount: Int) -> Int {
        precondition(paletteCount > 0)
        return Int(hash.magnitude % UInt(paletteCount))
    }
}

private struct AvatarRemoteImage: View {
    let url: URL

    @Environment(\.displayScale) private var displayScale
    @State private var phase = Phase.loading

    var body: some View {
        GeometryReader { proxy in
            let request = AvatarRemoteImageRequest(
                url: url,
                maxPixelSize: maxPixelSize(for: proxy.size, scale: displayScale)
            )

            content(for: request)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: request) {
                    await load(request)
                }
        }
    }

    @ViewBuilder
    private func content(for request: AvatarRemoteImageRequest) -> some View {
        switch phase {
        case .success(let loadedRequest, let image) where loadedRequest == request:
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .loading, .failure, .success:
            Color.clear
        }
    }

    private func load(_ request: AvatarRemoteImageRequest) async {
        phase = .loading
        do {
            let image = try await RemoteAvatarImageLoader.image(
                for: request.url,
                maxPixelSize: request.maxPixelSize,
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            phase = .success(request, image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(request)
        }
    }

    private func maxPixelSize(for size: CGSize, scale: CGFloat) -> Int {
        Int(ceil(max(size.width, size.height, 1) * max(scale, 1)))
    }

    private enum Phase {
        case loading
        case success(AvatarRemoteImageRequest, UIImage)
        case failure(AvatarRemoteImageRequest)
    }
}

private struct AvatarRemoteImageRequest: Hashable {
    let url: URL
    let maxPixelSize: Int
}
