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
                if let conversation, !conversation.mediaItems(for: record).isEmpty {
                    AttachmentTransfersView(groupID: conversation.group.groupIdHex,
                        items: conversation.mediaItems(for: record))
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

/// Every reaction on one message. Reads MDK's complete `messageReactions` list
/// and re-reads it on each installed conversation revision while open.
struct ReactionDetailsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let messageIdHex: String
    let viewModel: ConversationViewModel
    let onRemoveOwnReaction: ((String) -> Void)?
    @State private var selectedEmoji: String?
    @State private var model = MessageReactionsModel()
    @State private var retryCount = 0
    @State private var showsLoadingIndicator = false

    private struct LoadKey: Hashable {
        let subject: MessageReactionsSubject?
        let revision: ConversationWindowRevisionFfi?
        let runtimeReady: Bool
        let retry: Int
    }

    init(
        messageIdHex: String,
        viewModel: ConversationViewModel,
        initialEmoji: String?,
        onRemoveOwnReaction: ((String) -> Void)? = nil
    ) {
        self.messageIdHex = messageIdHex
        self.viewModel = viewModel
        self.onRemoveOwnReaction = onRemoveOwnReaction
        _selectedEmoji = State(initialValue: initialEmoji)
    }

    var body: some View {
        let subject = viewModel.messageReactionsSubject(for: messageIdHex)
        let content = content(for: subject)
        let isLoading = content == .loading
        NavigationStack {
            VStack(spacing: 0) {
                switch content {
                case .details(let details, let refreshError):
                    filters(details)
                    Divider()
                    if refreshError != nil {
                        refreshErrorRow
                    }
                    reactionList(details)
                case .loading:
                    Group {
                        if showsLoadingIndicator {
                            ProgressView(L10n.string("Loading…"))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t load reactions", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { retryCount += 1 }
                    }
                case .empty:
                    ContentUnavailableView {
                        Label("No reactions", systemImage: "face.smiling")
                    } description: {
                        Text("This message has no reactions, or it’s no longer available.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .onChange(of: ReactionDetailsPresentation.availableEmojis(in: content), initial: true) { _, available in
            selectedEmoji = ReactionDetailsPresentation.selection(selectedEmoji, availableEmojis: available)
        }
        .task(id: isLoading) {
            showsLoadingIndicator = false
            guard isLoading else { return }
            try? await Task.sleep(for: ReactionDetailsPresentation.loadingIndicatorDelay)
            if !Task.isCancelled { showsLoadingIndicator = true }
        }
        .task(id: LoadKey(
            subject: subject,
            revision: viewModel.conversationWindowRevision,
            runtimeReady: appState.canUseRuntimeForForegroundWork,
            retry: retryCount
        )) {
            guard let subject, appState.canUseRuntimeForForegroundWork,
                  let client = try? appState.currentMarmotClient() else { return }
            await model.load(subject, using: client)
        }
    }

    private func content(for subject: MessageReactionsSubject?) -> ReactionDetailsPresentation.Content {
        // Reactions read for another account, runtime or message are never shown.
        let isCurrent = subject != nil && model.subject == subject
        return ReactionDetailsPresentation.content(
            phase: isCurrent ? model.phase : .idle,
            hasLoaded: isCurrent && model.hasLoaded,
            reactions: isCurrent ? model.reactions : [],
            projected: viewModel.projectedReactionDetails(for: messageIdHex),
            me: viewModel.myAccountId ?? ""
        )
    }

    private var refreshErrorRow: some View {
        HStack(spacing: 12) {
            Text("Couldn’t refresh reactions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Retry") { retryCount += 1 }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
    }

    private func filters(_ details: ConversationViewModel.ReactionDetails) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(emoji: nil, count: details.totalReactionCount) {
                    Text(L10n.string("All"))
                }

                ForEach(details.groups) { group in
                    filterButton(emoji: group.emoji, count: group.count) {
                        CustomEmojiReactionLabel(emoji: group.emoji)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func filterButton<Label: View>(emoji: String?, count: Int,
                                           @ViewBuilder label: () -> Label) -> some View {
        let selected = selectedEmoji == emoji
        return Button {
            selectedEmoji = emoji
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                label()
                Text(L10n.formatted("%lld", Int64(count)))
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? WNNeutralAccent.foreground : Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                selected ? WNNeutralAccent.color(for: colorScheme) : Color(.tertiarySystemFill),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func reactionList(_ details: ConversationViewModel.ReactionDetails) -> some View {
        let users = sortedUsers(details)
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

    /// Reactors outside the window's identity sidecar resolve through the
    /// profile directory, like group members do.
    private func displayName(for sender: String) -> String {
        if viewModel.windowIdentities[sender] != nil {
            return viewModel.windowDisplayName(for: sender)
        }
        return appState.displayName(forAccountIdHex: sender)
    }

    private func sortedUsers(_ details: ConversationViewModel.ReactionDetails) -> [ConversationViewModel.ReactionDetails.User] {
        let users = details.users(filteredBy: selectedEmoji)
        let namesBySender = Dictionary(uniqueKeysWithValues: users.map { ($0.sender, displayName(for: $0.sender)) })
        let me = viewModel.myAccountId

        return users.sorted { lhs, rhs in
            let lhsIsMe = lhs.sender == me
            let rhsIsMe = rhs.sender == me
            if lhsIsMe != rhsIsMe { return lhsIsMe }

            let lhsName = namesBySender[lhs.sender] ?? lhs.sender
            let rhsName = namesBySender[rhs.sender] ?? rhs.sender
            let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            return comparison == .orderedSame ? lhs.sender < rhs.sender : comparison == .orderedAscending
        }
    }

    private func reactionRow(_ user: ConversationViewModel.ReactionDetails.User) -> some View {
        let name = displayName(for: user.sender)
        let isMe = user.sender == viewModel.myAccountId

        return HStack(spacing: 12) {
            NativeAvatarBubble(seed: user.sender, title: name,
                               asset: viewModel.windowIdentities[user.sender]?.avatarAsset)
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
                                CustomEmojiReactionLabel(emoji: emoji)
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
                        .accessibilityValue(CustomEmojiShortcode.spokenReaction(emoji))
                    } else {
                        CustomEmojiReactionLabel(emoji: emoji)
                            .font(.title3)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
