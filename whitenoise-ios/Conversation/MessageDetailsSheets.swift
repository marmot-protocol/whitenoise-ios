import SwiftUI
import MarmotKit

enum MessageInfoPresentation {
    @MainActor
    static func statusLabel(for status: MessageStatus) -> String {
        switch status {
        case .received: L10n.string("Received")
        case .sending: L10n.string("Sending…")
        case .sent: L10n.string("Sent")
        case .failed: L10n.string("Not delivered")
        case .streaming: L10n.string("Streaming…")
        }
    }

    @MainActor
    static func timestampLabel(
        _ timestamp: UInt64,
        locale: Locale = AppLanguage.currentLocale
    ) -> String? {
        guard timestamp > 0 else { return nil }
        let style = Date.FormatStyle(date: .long, time: .standard).locale(locale)
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(style)
    }
}

struct MessageInfoSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let record: AppMessageRecordFfi
    let status: MessageStatus
    var conversation: ConversationViewModel?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    senderCard
                }

                Section {
                    detailsCard
                }
                if let conversation, conversation.canReadReports {
                    MessageReportsSection(messageID: record.messageIdHex, conversation: conversation)
                }
            }
            .navigationTitle("Message info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var senderCard: some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: record.sender,
                title: senderName,
                pictureURL: appState.avatarURL(forAccountIdHex: record.sender)
            )
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(senderName)
                        .font(.headline)
                    if isFromMe {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(appState.shortNpub(forAccountIdHex: record.sender))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            infoRow(
                title: "Status",
                value: MessageInfoPresentation.statusLabel(for: status),
                systemImage: statusSystemImage,
                valueColor: status == .failed ? .red : .primary
            )

            Divider().padding(.leading, 44)

            infoRow(
                title: "Sent",
                value: MessageInfoPresentation.timestampLabel(record.recordedAt) ?? L10n.string("Unknown"),
                systemImage: "paperplane"
            )

            Divider().padding(.leading, 44)

            infoRow(
                title: "Received",
                value: MessageInfoPresentation.timestampLabel(record.receivedAt) ?? L10n.string("Unknown"),
                systemImage: "tray.and.arrow.down"
            )

            if hasExpirationTimer {
                Divider().padding(.leading, 44)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    infoRow(
                        title: "Expires",
                        value: MessageExpirationPresentation.detailLabel(
                            expiresAt: record.retentionExpiresAt,
                            now: context.date
                        ) ?? L10n.string("Unknown"),
                        systemImage: MessageExpirationPresentation.systemImage
                    )
                }
            }
        }
    }

    private func infoRow(
        title: LocalizedStringKey,
        value: String,
        systemImage: String,
        valueColor: Color = .primary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var senderName: String {
        appState.displayName(forAccountIdHex: record.sender)
    }

    private var isFromMe: Bool {
        record.direction == "sent"
    }

    private var hasExpirationTimer: Bool {
        MessageExpirationPresentation.showsIndicator(
            retentionSeconds: record.retentionSeconds,
            expiresAt: record.retentionExpiresAt
        )
    }

    private var statusSystemImage: String {
        switch status {
        case .received: "tray.and.arrow.down.fill"
        case .sending: "clock"
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .streaming: "ellipsis.bubble.fill"
        }
    }
}

struct ReactionDetailsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let details: ConversationViewModel.ReactionDetails
    let onRemoveOwnReaction: ((String) -> Void)?
    var identityName: ((String) -> String)?
    var identityAvatar: ((String) -> URL?)?
    var identityAvatarAsset: ((String) -> AvatarAssetFfi?)?
    @State private var selectedEmoji: String?

    init(
        details: ConversationViewModel.ReactionDetails,
        initialEmoji: String?,
        onRemoveOwnReaction: ((String) -> Void)? = nil,
        identityName: ((String) -> String)? = nil,
        identityAvatar: ((String) -> URL?)? = nil,
        identityAvatarAsset: ((String) -> AvatarAssetFfi?)? = nil
    ) {
        self.details = details
        self.onRemoveOwnReaction = onRemoveOwnReaction
        self.identityName = identityName
        self.identityAvatar = identityAvatar
        self.identityAvatarAsset = identityAvatarAsset
        _selectedEmoji = State(initialValue: initialEmoji)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                Divider()
                if details.isTruncated {
                    Text("Showing a limited preview of reactions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                reactionList
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if let selectedEmoji, !details.groups.contains(where: { $0.emoji == selectedEmoji }) {
                self.selectedEmoji = nil
            }
        }
        .onChange(of: details.groups.map(\.emoji)) { _, availableEmojis in
            if let selectedEmoji, !availableEmojis.contains(selectedEmoji) {
                self.selectedEmoji = nil
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(
                    emoji: nil,
                    label: L10n.string("All"),
                    count: details.totalReactionCount
                )

                ForEach(details.groups) { group in
                    filterButton(
                        emoji: group.emoji,
                        label: ContentSanitizer.reactionEmoji(group.emoji),
                        count: group.count
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func filterButton(emoji: String?, label: String, count: Int) -> some View {
        let selected = selectedEmoji == emoji
        return Button {
            selectedEmoji = emoji
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Text(label)
                Text(L10n.formatted("%lld", Int64(count)))
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? WNNeutralAccent.foreground : Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(
                selected ? Color.accentColor : Color(.tertiarySystemFill),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var reactionList: some View {
        let users = sortedUsers
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(users) { user in
                    reactionRow(user)
                    if user.id != users.last?.id {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var sortedUsers: [ConversationViewModel.ReactionDetails.User] {
        let users = details.users(filteredBy: selectedEmoji)
        let namesBySender = Dictionary(uniqueKeysWithValues: users.map { user in
            (user.sender, (identityName?(user.sender) ?? appState.displayName(forAccountIdHex: user.sender)))
        })

        return users.sorted { lhs, rhs in
            let lhsIsMe = lhs.sender == appState.activeAccount?.accountIdHex
            let rhsIsMe = rhs.sender == appState.activeAccount?.accountIdHex
            if lhsIsMe != rhsIsMe { return lhsIsMe }

            let lhsName = namesBySender[lhs.sender] ?? lhs.sender
            let rhsName = namesBySender[rhs.sender] ?? rhs.sender
            let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            return comparison == .orderedSame ? lhs.sender < rhs.sender : comparison == .orderedAscending
        }
    }

    private func reactionRow(_ user: ConversationViewModel.ReactionDetails.User) -> some View {
        let name = (identityName?(user.sender) ?? appState.displayName(forAccountIdHex: user.sender))
        let isMe = user.sender == appState.activeAccount?.accountIdHex

        return HStack(spacing: 12) {
            Group {
                if let identityAvatarAsset {
                    NativeAvatarBubble(seed: user.sender, title: name, asset: identityAvatarAsset(user.sender))
                } else {
                    AvatarBubble(
                        seed: user.sender,
                        title: name,
                        pictureURL: identityAvatar != nil ? identityAvatar?(user.sender) : appState.avatarURL(forAccountIdHex: user.sender)
                    )
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))
                    if isMe {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(appState.shortNpub(forAccountIdHex: user.sender))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 5) {
                ForEach(user.emojis, id: \.self) { emoji in
                    if isMe, let onRemoveOwnReaction {
                        Button {
                            onRemoveOwnReaction(emoji)
                        } label: {
                            HStack(spacing: 3) {
                                Text(ContentSanitizer.reactionEmoji(emoji))
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.title3)
                            .padding(.leading, 7)
                            .padding(.trailing, 5)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("Remove"))
                        .accessibilityValue(ContentSanitizer.reactionEmoji(emoji))
                    } else {
                        Text(ContentSanitizer.reactionEmoji(emoji))
                            .font(.title3)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
