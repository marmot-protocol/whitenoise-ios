import SwiftUI
import MarmotKit

/// What retained attachments hold on this device for the active profile, and
/// bulk removal. MDK owns the bytes; this screen only reads and asks it to remove.
struct ManageStorageView: View {
    @Environment(AppState.self) private var appState
    @State private var model: ManageStorageModel
    @State private var pendingRemoval: ManageStoragePresentation.RemovalCutoff?
    @State private var pendingKeepMedia: ManageStoragePresentation.KeepMedia.Confirmation?

    init(model: ManageStorageModel? = nil) {
        _model = State(initialValue: model ?? ManageStorageModel())
    }

    var body: some View {
        Form {
            usageSection
            if let notice = model.usage?.migration {
                ManageStorageMigrationSection(notice: notice)
            }
            keepMediaSection
            cacheSection
            freeUpSpaceSection
            chatsSection
        }
        .disabled(model.operation != nil)
        .productScreen(.settings, section: .storage)
        .localizedNavigationTitle("Manage Storage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.bind(using: appState) }
        .task(id: bindingKey) {
            await model.bind(using: appState)
            await model.followPresentedRows(using: appState)
        }
        .task(id: usageRefreshKey) {
            guard let delay = model.usageRefresh.nextDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await model.refreshUsage(using: appState)
        }
        .removeOlderConfirmation($pendingRemoval, scope: .account, model: model)
        .confirmationDialog(
            pendingKeepMedia?.title ?? "",
            isPresented: Binding(get: { pendingKeepMedia != nil }, set: { if !$0 { pendingKeepMedia = nil } }),
            titleVisibility: .visible,
            presenting: pendingKeepMedia
        ) { confirmation in
            Button(confirmation.action, role: .destructive) {
                setKeepMedia(confirmation.keep, confirmed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var bindingKey: String {
        "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(appState.canUseRuntimeForLocalForegroundWork)"
    }

    private var usageRefreshKey: String {
        "\(model.epoch)/\(model.usageRefresh.revision)"
    }

    @ViewBuilder
    private var usageSection: some View {
        Section {
            if let usage = model.usage {
                LabeledContent {
                    Text(ManageStoragePresentation.byteText(usage.attachmentBytes))
                } label: {
                    Text("Attachments")
                    Text(L10n.plural("%lld attachments", usage.attachmentCount))
                }
                LabeledContent("Messages and Chat Data",
                               value: ManageStoragePresentation.byteText(usage.chatDataBytes))
                if usage.unusedDatabaseBytes > 0 {
                    LabeledContent {
                        Text(ManageStoragePresentation.byteText(usage.unusedDatabaseBytes))
                    } label: {
                        Text("Unused Database Space")
                        Text("Still held by the chat database file")
                    }
                }
                // Stale figures stay visible, but not as if they were current.
                if model.usageRefresh.failed {
                    ManageStorageRetryRow(message: L10n.string("Couldn't load storage usage")) {
                        Task { await model.refreshUsage(using: appState) }
                    }
                }
            } else if model.usageRefresh.failed {
                ManageStorageRetryRow(message: L10n.string("Couldn't load storage usage")) {
                    Task { await model.bind(using: appState) }
                }
            } else {
                ManageStorageLoadingRow()
            }
        } header: {
            Text("Storage Used")
        } footer: {
            Text("What this profile keeps on this device. Other profiles are counted separately.")
        }
    }

    @ViewBuilder
    private var keepMediaSection: some View {
        Section {
            if let keep = model.keepMedia {
                if model.operation == .keepMedia {
                    LabeledContent("Keep Media") { ProgressView() }
                } else {
                    Picker("Keep Media", selection: Binding(get: { keep }, set: { chooseKeepMedia($0, current: keep) })) {
                        ForEach(ManageStoragePresentation.KeepMedia.options, id: \.self) { option in
                            Text(ManageStoragePresentation.KeepMedia.title(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if model.failedOperation == .keepMedia {
                    ManageStorageFailureRow(message: L10n.string("Couldn't change Keep Media. Try again."))
                }
            } else if model.keepMediaFailed {
                ManageStorageRetryRow(message: L10n.string("Couldn't load Keep Media")) {
                    Task { await model.refreshKeepMedia(using: appState) }
                }
            } else {
                ManageStorageLoadingRow()
            }
        } footer: {
            Text("This profile's attachments older than this are removed from this device automatically. Downloading one again keeps it for the full period from then.")
        }
    }

    private func chooseKeepMedia(_ next: AttachmentKeepMediaFfi, current: AttachmentKeepMediaFfi) {
        guard next != current else { return }
        if let confirmation = ManageStoragePresentation.KeepMedia.confirmation(from: current, to: next) {
            pendingKeepMedia = confirmation
        } else {
            setKeepMedia(next, confirmed: false)
        }
    }

    private func setKeepMedia(_ keep: AttachmentKeepMediaFfi, confirmed: Bool) {
        Task {
            guard let removed = await model.setKeepMedia(keep, using: appState),
                  let text = ManageStoragePresentation.KeepMedia.resultText(removed: removed, confirmed: confirmed)
            else { return }
            appState.present(.success(text))
        }
    }

    private var cacheSection: some View {
        Section {
            LabeledContent("Profile and Group Pictures",
                           value: model.usage.map { ManageStoragePresentation.byteText($0.cacheBytes) } ?? "—")
            Button {
                Task { await model.clearCache(using: appState) }
            } label: {
                ManageStorageActionLabel(title: L10n.string("Clear Cache"),
                                         inProgress: model.operation == .clearCache)
            }
            .disabled(model.usage == nil || model.usage?.cacheBytes == 0)
            if model.failedOperation == .clearCache {
                ManageStorageFailureRow(message: L10n.string("Couldn't clear the cache. Try again."))
            }
        } header: {
            Text("Cache")
        } footer: {
            Text("Pictures download again when you need them.")
        }
    }

    private var freeUpSpaceSection: some View {
        Section {
            NavigationLink {
                LargestAttachmentsView(model: model)
            } label: {
                Text("Largest Attachments")
            }
            ManageStorageRemoveOlderMenu(pendingRemoval: $pendingRemoval,
                                         inProgress: model.operation == .removeOlder(.account))
                .disabled(model.usage == nil || model.usage?.attachmentCount == 0)
            if model.failedOperation == .removeOlder(.account) {
                ManageStorageFailureRow(message: L10n.string("Couldn't remove attachments. Try again."))
            }
        } header: {
            Text("Free Up Space")
        } footer: {
            Text("Removed attachments stay in their messages. You can download them again while they're still available.")
        }
    }

    @ViewBuilder
    private var chatsSection: some View {
        Section {
            ForEach(model.chats.items, id: \.groupIdHex) { chat in
                NavigationLink {
                    ChatStorageView(model: model, groupIdHex: chat.groupIdHex)
                } label: {
                    ManageStorageChatRow(identity: model.identity(for: chat.groupIdHex), usage: chat)
                }
            }
            if model.chatsFailed {
                ManageStorageRetryRow(message: L10n.string("Couldn't load chats")) {
                    Task { await model.loadMoreChats(using: appState) }
                }
            } else if model.chats.hasMore {
                ManageStorageLoadingRow()
                    .task(id: "\(model.epoch)/\(model.chats.pageCount)") {
                        await model.loadMoreChats(using: appState)
                    }
            } else if model.chats.items.isEmpty {
                Text("No downloaded attachments")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Chats")
        } footer: {
            if !model.chats.items.isEmpty {
                Text("An attachment shared in more than one chat counts in each.")
            }
        }
    }
}

/// One chat's attachments, largest first, with bulk removal for that chat.
struct ChatStorageView: View {
    @Environment(AppState.self) private var appState
    let model: ManageStorageModel
    let groupIdHex: String
    @State private var pendingRemoval: ManageStoragePresentation.RemovalCutoff?
    @State private var confirmsRemoveAll = false

    var body: some View {
        let identity = model.identity(for: groupIdHex)
        let scope = ManageStorageModel.Scope.chat(groupIdHex)
        Form {
            if let usage = model.chatUsage(groupIdHex) {
                Section {
                    ManageStorageChatRow(identity: identity, usage: usage)
                }
            }
            Section {
                Button(role: .destructive) {
                    confirmsRemoveAll = true
                } label: {
                    ManageStorageActionLabel(title: L10n.string("Remove All Attachments"),
                                             inProgress: model.operation == .removeChat(groupIdHex))
                }
                ManageStorageRemoveOlderMenu(pendingRemoval: $pendingRemoval,
                                             inProgress: model.operation == .removeOlder(scope))
                if model.failedOperation == .removeChat(groupIdHex) || model.failedOperation == .removeOlder(scope) {
                    ManageStorageFailureRow(message: L10n.string("Couldn't remove attachments. Try again."))
                }
            } footer: {
                Text("Removed attachments stay in their messages. You can download them again while they're still available.")
            }
            RetainedAttachmentsSection(model: model, scope: scope)
        }
        .disabled(model.operation != nil)
        .navigationTitle(identity.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            L10n.formatted("Remove all attachments in “%@”?", identity.title),
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All Attachments", role: .destructive) {
                Task { await model.removeAllAttachments(inChat: groupIdHex, using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded attachment in this chat is removed from this device. Messages stay, and you can download attachments again while they're still available.")
        }
        .removeOlderConfirmation($pendingRemoval, scope: scope, model: model)
    }
}

/// Every retained attachment for this profile, largest first.
struct LargestAttachmentsView: View {
    let model: ManageStorageModel

    var body: some View {
        Form {
            RetainedAttachmentsSection(model: model, scope: .account)
        }
        .disabled(model.operation != nil)
        .localizedNavigationTitle("Largest Attachments")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RetainedAttachmentsSection: View {
    @Environment(AppState.self) private var appState
    let model: ManageStorageModel
    let scope: ManageStorageModel.Scope

    var body: some View {
        let pages = model.attachmentPages(scope)
        Section {
            ForEach(pages.items, id: \.self) { attachment in
                let id = ManageStoragePresentation.attachmentID(attachment)
                ManageStorageAttachmentRow(
                    attachment: attachment,
                    chatTitle: scope == .account ? model.identity(for: attachment.groupIdHex).title : nil,
                    inProgress: model.operation == .removeAttachment(id),
                    failed: model.failedOperation == .removeAttachment(id)
                ) {
                    Task { await model.remove(attachment, using: appState) }
                }
            }
            if model.attachmentsFailed.contains(scope) {
                ManageStorageRetryRow(message: L10n.string("Couldn't load attachments")) {
                    Task { await model.loadMoreAttachments(scope, using: appState) }
                }
            } else if pages.hasMore {
                ManageStorageLoadingRow()
                    .task(id: "\(model.epoch)/\(pages.pageCount)") {
                        await model.loadMoreAttachments(scope, using: appState)
                    }
            } else if pages.items.isEmpty {
                Text("No downloaded attachments")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Largest First")
        }
    }
}

private struct ManageStorageMigrationSection: View {
    let notice: ManageStoragePresentation.MigrationNotice

    var body: some View {
        Section {
            switch notice {
            case .moving(let remaining):
                LabeledContent {
                    Text(L10n.formatted("%@ remaining", ManageStoragePresentation.byteText(remaining)))
                } label: {
                    Label("Updating Attachment Storage", systemImage: "arrow.triangle.2.circlepath")
                }
            case .paused(let needed):
                LabeledContent {
                    Text(L10n.formatted("Needs %@ free", ManageStoragePresentation.byteText(needed)))
                } label: {
                    Label("Attachment Storage Update Paused", systemImage: "pause.circle")
                }
            case .compacting:
                LabeledContent {
                    ProgressView()
                } label: {
                    Label("Reclaiming Space", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
        } footer: {
            switch notice {
            case .moving:
                Text("Older attachments are moving out of the chat database in the background. Nothing is deleted.")
            case .paused:
                Text("Free up space on this device, or remove attachments below, to continue. Nothing is deleted automatically.")
            case .compacting:
                Text("Returning freed space to your device. Chats may pause for a moment.")
            }
        }
    }
}

private struct ManageStorageChatRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let identity: ManageStorageModel.ChatIdentity
    let usage: ChatAttachmentUsageFfi

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: stacked ? .top : .center, spacing: 12) {
            NativeAvatarBubble(seed: identity.seed, title: identity.title, asset: identity.avatarAsset)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.title)
                    .lineLimit(stacked ? nil : 1)
                Text(L10n.plural("%lld attachments", usage.attachmentCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if stacked { size }
            }
            if !stacked {
                Spacer(minLength: 8)
                size
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var size: some View {
        Text(ManageStoragePresentation.byteText(usage.bytes))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

private struct ManageStorageAttachmentRow: View {
    let attachment: RetainedAttachmentSummaryFfi
    let chatTitle: String?
    let inProgress: Bool
    let failed: Bool
    let onRemove: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: stacked ? .top : .center, spacing: 12) {
            Image(systemName: ManageStoragePresentation.attachmentKind(attachment).systemImageName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ManageStoragePresentation.attachmentTitle(attachment))
                    .lineLimit(stacked ? nil : 1)
                Text(ManageStoragePresentation.attachmentSubtitle(attachment, chatTitle: chatTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(stacked ? nil : 1)
                if stacked { size }
                if failed {
                    Text("Couldn't remove this attachment. Try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if !stacked {
                Spacer(minLength: 8)
                size
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Remove"), onRemove)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var size: some View {
        if inProgress {
            ProgressView()
        } else {
            Text(ManageStoragePresentation.byteText(attachment.byteCount))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ManageStorageRemoveOlderMenu: View {
    @Binding var pendingRemoval: ManageStoragePresentation.RemovalCutoff?
    let inProgress: Bool

    var body: some View {
        Menu {
            ForEach(ManageStoragePresentation.RemovalAge.allCases, id: \.self) { age in
                Button(age.title) {
                    pendingRemoval = ManageStoragePresentation.RemovalCutoff(age: age, now: Date(), calendar: .current)
                }
            }
        } label: {
            ManageStorageActionLabel(title: L10n.string("Remove Older Attachments"), inProgress: inProgress)
        }
    }
}

/// Keeps progress inside the initiating control without changing its size.
private struct ManageStorageActionLabel: View {
    let title: String
    let inProgress: Bool

    var body: some View {
        HStack {
            Text(title)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if inProgress { ProgressView() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

private struct ManageStorageLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .accessibilityLabel(Text("Loading…"))
    }
}

private struct ManageStorageRetryRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
        }
    }
}

private struct ManageStorageFailureRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

private extension View {
    func removeOlderConfirmation(_ cutoff: Binding<ManageStoragePresentation.RemovalCutoff?>,
                                 scope: ManageStorageModel.Scope,
                                 model: ManageStorageModel) -> some View {
        modifier(RemoveOlderConfirmation(cutoff: cutoff, scope: scope, model: model))
    }
}

private struct RemoveOlderConfirmation: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var cutoff: ManageStoragePresentation.RemovalCutoff?
    let scope: ManageStorageModel.Scope
    let model: ManageStorageModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.string("Remove Older Attachments?"),
            isPresented: Binding(get: { cutoff != nil }, set: { if !$0 { cutoff = nil } }),
            titleVisibility: .visible,
            presenting: cutoff
        ) { cutoff in
            Button("Remove Attachments", role: .destructive) {
                Task { await model.removeOlder(than: cutoff, in: scope, using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { cutoff in
            let day = cutoff.text()
            Text(scope == .account
                ? L10n.formatted("Attachments received before %@ are removed from this device in every chat. Messages stay, and you can download attachments again while they're still available.", day)
                : L10n.formatted("Attachments in this chat received before %@ are removed from this device. Messages stay, and you can download attachments again while they're still available.", day))
        }
    }
}

#if DEBUG
#Preview("Manage Storage") {
    let mebibyte: UInt64 = 1_048_576
    let now = UInt64(Date().timeIntervalSince1970)
    let attachments = [
        RetainedAttachmentSummaryFfi(
            groupIdHex: "a1", target: AttachmentLocalTargetFfi(messageIdHex: "m1", sourceMessageIdHex: "m1",
                                                               attachmentIndex: 0),
            byteCount: 182 * mebibyte, mediaType: "video/mp4", fileName: "Trailhead.mov", receivedAt: now - 3_600),
        RetainedAttachmentSummaryFfi(
            groupIdHex: "b2", target: AttachmentLocalTargetFfi(messageIdHex: "m2", sourceMessageIdHex: "m2",
                                                               attachmentIndex: 0),
            byteCount: 24 * mebibyte, mediaType: "application/pdf", fileName: "Itinerary.pdf",
            receivedAt: now - 9 * 86_400),
        RetainedAttachmentSummaryFfi(
            groupIdHex: "a1", target: AttachmentLocalTargetFfi(messageIdHex: "m3", sourceMessageIdHex: "m3",
                                                               attachmentIndex: 1),
            byteCount: 3 * mebibyte, mediaType: "image/jpeg", fileName: "", receivedAt: now - 40 * 86_400),
    ]
    let model = ManageStorageModel.fixture(
        usage: AttachmentStorageUsageFfi(mediaBytes: 209 * mebibyte, legacyBytes: 0, attachmentCount: 3,
                                         databaseBytes: 18 * mebibyte, databaseFreeBytes: 6 * mebibyte,
                                         migration: .paused, migrationBytes: 640 * mebibyte,
                                         cacheBytes: 6 * mebibyte),
        chats: [
            (ChatAttachmentUsageFfi(groupIdHex: "a1", bytes: 185 * mebibyte, attachmentCount: 2), "Weekend Hike"),
            (ChatAttachmentUsageFfi(groupIdHex: "b2", bytes: 24 * mebibyte, attachmentCount: 1), "Alex"),
        ],
        attachments: attachments
    )
    NavigationStack {
        ManageStorageView(model: model)
    }
    .environment(AppState(client: nil, notifications: .shared))
}
#endif
