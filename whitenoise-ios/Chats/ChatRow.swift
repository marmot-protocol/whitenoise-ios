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
            GroupAvatarBubble(
                groupIdHex: item.id,
                imageHashHex: encryptedImageHashHex,
                seed: item.avatarSeed,
                title: title,
                pictureURL: avatarURLForDisplay,
                loadPriority: .chatList
            )
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if item.isMuted {
                        Image(systemName: MuteBadgePresentation.systemImageName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(L10n.string("Muted")))
                    }
                    if item.isDisbanding {
                        Image(systemName: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(L10n.string("Ending group…")))
                    } else if item.isDisbanded {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(L10n.string("Group ended")))
                    } else if item.departureStatus == .leaving {
                        Image(systemName: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(L10n.string("Leaving…")))
                    } else if case .membershipEnded(let membership) = item.departureStatus {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                membership == .left
                                    ? Text("Left chat")
                                    : Text("Removed from chat")
                            )
                    }
                    Spacer(minLength: 8)
                    if let timestamp {
                        Text(timestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                HStack(alignment: .top, spacing: 5) {
                    previewText
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if item.isPinned {
                        Image(systemName: PinBadgePresentation.systemImageName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(PinBadgePresentation.rotationDegrees))
                            .accessibilityLabel(Text(L10n.string("Pinned")))
                    }
                    if item.hasUnread {
                        UnreadCountBadge(count: item.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        item.title
    }

    private var encryptedImageHashHex: String? {
        guard !item.row.pendingConfirmation else { return nil }
        if let selected = item.selectedAvatar {
            if case .encryptedGroupImage(let image, _) = selected { return image.imageHashHex }
            return nil
        }
        return item.row.avatar?.imageHashHex
    }

    private var avatarURLForDisplay: URL? {
        if encryptedImageHashHex != nil, item.selectedAvatar != nil || ContentSanitizer.imageURL(item.row.avatarUrl) == nil {
            return nil
        }
        return Self.automaticAvatarURL(
            item.avatarURL,
            pendingConfirmation: item.row.pendingConfirmation
        )
    }

    private var preview: ChatRowPreviewPresentation {
        Self.previewPresentation(
            for: item,
            activeAccountIdHex: appState.activeAccount?.accountIdHex,
            senderName: { appState.displayName(forAccountIdHex: $0) }
        )
    }

    private var previewText: Text {
        if let prefix = preview.prefix {
            return Text(verbatim: prefix + ": ")
                .bold()
                + Text(verbatim: preview.body)
        }
        return Text(verbatim: preview.body)
    }

    static func previewPresentation(
        for item: ChatsListViewModel.Item,
        activeAccountIdHex: String?,
        senderName: (String) -> String
    ) -> ChatRowPreviewPresentation {
        switch item.departureStatus {
        case .leaving:
            return ChatRowPreviewPresentation(prefix: nil, body: L10n.string("Leaving…"))
        case .membershipEnded(.left):
            return ChatRowPreviewPresentation(prefix: nil, body: L10n.string("You left this chat."))
        case .membershipEnded:
            return ChatRowPreviewPresentation(prefix: nil, body: L10n.string("You were removed from this chat."))
        case .pendingInvite:
            return ChatRowPreviewPresentation(
                prefix: nil,
                body: ConversationInvitePresentation.invitationText(
                    inviterName: item.inviterAccountIdHex.map(senderName)
                )
            )
        case nil:
            break
        }
        if let draftPreview = item.draftPreview {
            return ChatRowPreviewPresentation(prefix: nil, body: L10n.formatted("Draft: %@", draftPreview))
        }
        guard let latest = item.lastMessage else {
            return ChatRowPreviewPresentation(prefix: nil, body: L10n.string("No messages yet"))
        }
        let body = item.previewText ?? ""
        if latest.kind == MessageSemantics.kindGroupSystem {
            return ChatRowPreviewPresentation(
                prefix: nil,
                body: body.isEmpty ? L10n.string("Group membership updated") : body
            )
        }
        if latest.sender == activeAccountIdHex {
            return body.isEmpty
                ? ChatRowPreviewPresentation(prefix: nil, body: L10n.string("You sent a message"))
                : ChatRowPreviewPresentation(prefix: L10n.string("You"), body: body)
        }
        if item.isDirectMessage == false, !body.isEmpty {
            let projectedName = ContentSanitizer.displayName(latest.senderDisplayName)
            let fallbackName = ContentSanitizer.displayName(senderName(latest.sender))
            if let name = projectedName ?? fallbackName {
                return ChatRowPreviewPresentation(prefix: name, body: body)
            }
        }
        return ChatRowPreviewPresentation(
            prefix: nil,
            body: body.isEmpty ? L10n.string("New message") : body
        )
    }

    static func automaticAvatarURL(_ url: URL?, pendingConfirmation: Bool) -> URL? {
        pendingConfirmation ? nil : url
    }

    private var timestamp: String? {
        guard let latest = item.lastMessage else { return nil }
        return RelativeTime.chatList(Date(timeIntervalSince1970: TimeInterval(latest.timelineAt)))
    }

}

nonisolated struct ChatRowPreviewPresentation: Equatable {
    let prefix: String?
    let body: String
}

struct MentionBadge: View {
    var body: some View {
        Image(systemName: MentionBadgePresentation.systemImageName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.orange))
            .accessibilityLabel(Text(verbatim: "Unread mention"))
    }
}

nonisolated enum MentionBadgePresentation {
    static let systemImageName = "at"
}

nonisolated enum MuteBadgePresentation {
    static let systemImageName = "bell.slash.fill"
}

nonisolated enum PinBadgePresentation {
    static let systemImageName = "pin.fill"
    static let rotationDegrees = 45.0
}

/// Circular avatar. Renders the profile picture when a URL is provided,
/// otherwise falls back to initials over a deterministic color derived from
/// the seed string (so a given group/person keeps the same color).
struct AvatarBubble: View {
    let seed: String
    let title: String
    var pictureURL: URL? = nil
    var pictureImage: UIImage? = nil

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
                } else if let pictureImage {
                    opaqueAvatarImage(pictureImage)
                }
            }
            .clipShape(Circle())
    }

    private func opaqueAvatarImage(_ image: UIImage) -> some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
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

/// Group avatar renderer. URL components retain precedence for backwards
/// compatibility; otherwise the content-addressed encrypted Blossom image is
/// fetched and decrypted through Marmot.
struct GroupAvatarBubble: View {
    @Environment(AppState.self) private var appState
    @Environment(\.displayScale) private var displayScale

    let groupIdHex: String
    let imageHashHex: String?
    let seed: String
    let title: String
    var pictureURL: URL? = nil
    var loadPriority: GroupAvatarLoadPriority = .foreground

    @State private var phase = Phase.idle

    var body: some View {
        GeometryReader { proxy in
            let request = request(
                size: proxy.size,
                scale: displayScale,
                accountRef: appState.activeAccountRef
            )
            AvatarBubble(
                seed: seed,
                title: title,
                pictureURL: pictureURL,
                pictureImage: image(for: request)
            )
            .task(id: request) {
                await load(request)
            }
        }
    }

    private func request(
        size: CGSize,
        scale: CGFloat,
        accountRef: String?
    ) -> GroupAvatarImageRequest? {
        guard pictureURL == nil,
              let accountRef,
              let imageHashHex,
              !imageHashHex.isEmpty
        else { return nil }
        return GroupAvatarImageRequest(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            imageHashHex: imageHashHex,
            maxPixelSize: Int(ceil(max(size.width, size.height, 1) * max(scale, 1)))
        )
    }

    private func image(for request: GroupAvatarImageRequest?) -> UIImage? {
        if let request, let cached = GroupAvatarImageLoader.cachedImage(for: request) {
            return cached
        }
        guard case .success(let loadedRequest, let image) = phase,
              loadedRequest == request
        else { return nil }
        return image
    }

    private func load(_ request: GroupAvatarImageRequest?) async {
        guard let request else {
            phase = .idle
            return
        }
        phase = .loading(request)
        do {
            let client = try appState.currentMarmotClient()
            let image = try await GroupAvatarImageLoader.image(
                request: request,
                scale: displayScale,
                priority: loadPriority,
                client: client
            )
            guard !Task.isCancelled else { return }
            phase = .success(request, image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(request)
        }
    }

    private enum Phase {
        case idle
        case loading(GroupAvatarImageRequest)
        case success(GroupAvatarImageRequest, UIImage)
        case failure(GroupAvatarImageRequest)
    }
}

struct AvatarRemoteImage: View {
    let url: URL

    @Environment(AppState.self) private var appState: AppState?
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
        if let cached = RemoteAvatarImageLoader.cachedImage(
            for: request.url,
            maxPixelSize: request.maxPixelSize
        ) {
            opaqueAvatarImage(cached)
        } else if case .success(let loadedRequest, let image) = phase,
                  loadedRequest == request {
            opaqueAvatarImage(image)
        } else {
            Color.clear
        }
    }

    private func opaqueAvatarImage(_ image: UIImage) -> some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
    }

    private func load(_ request: AvatarRemoteImageRequest) async {
        phase = .loading
        do {
            let client = try? appState?.currentMarmotClient()
            let image = try await RemoteAvatarImageLoader.image(
                for: request.url,
                maxPixelSize: request.maxPixelSize,
                scale: displayScale,
                fetch: { url in
                    if let client {
                        return try await client.downloadProfileImage(
                            url: url.absoluteString,
                            maxBytes: UInt64(RemoteImageFetch.maximumImageBytes)
                        )
                    }
                    return try await RemoteImageFetch.imageData(for: url)
                }
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
