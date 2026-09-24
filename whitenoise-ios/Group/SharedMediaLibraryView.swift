import SwiftUI
import MarmotKit

/// Screen store for the shared-media library: media records plus a bounded
/// link scan over message history. Both loads run off the MainActor through
/// the client wrappers.
@MainActor
@Observable
final class SharedMediaLibraryViewModel {
    private(set) var items: [GroupSharedMediaItem] = []
    // Derived once per load: `body` re-runs on segment switches and gallery
    // presentation, and regrouping every item plus a fresh DateFormatter per
    // render is pure waste for a media-heavy group.
    private(set) var visualItems: [GroupSharedMediaItem] = []
    private(set) var visualMonthSections: [SharedMediaLibraryPresentation.MonthSection] = []
    private(set) var links: [SharedMediaLibraryPresentation.LinkItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingLinks = false
    private(set) var linksTruncated = false
    var loadError: String?
    var linksError: String?
    private var cursor: AttachmentHistoryCursor?
    private var version: AttachmentHistoryVersion?
    private(set) var hasMore = false
    private(set) var hasNewAttachments = false
    private var scope: String?
    private var generation = 0
    private var didLoad = false
    private var didLoadLinks = false

    /// Month titles and buckets bake in the calendar and locale at build
    /// time; a language or time-zone change while the screen stays alive
    /// re-derives them (wired via notifications in the view).
    func rebuildMonthSections() {
        visualMonthSections = SharedMediaLibraryPresentation.monthSections(visualItems)
    }

    static let linkScanMessageLimit = 2000
    static let linkScanPageLimit: UInt32 = 200

    func load(groupIdHex: String, using appState: AppState, force: Bool = false, nextPage: Bool = false) async {
        guard let accountRef = appState.activeAccountRef else {
            generation += 1
            scope = nil
            resetPages()
            links = []
            isLoading = false
            isLoadingLinks = false
            return
        }
        let newScope = "\(accountRef)/\(appState.runtimeGeneration)/\(groupIdHex)"
        if scope != newScope {
            generation += 1
            scope = newScope
            isLoading = false
            resetPages()
            didLoadLinks = false
            isLoadingLinks = false
            links = []
        }
        guard !isLoading || force, force || nextPage || !didLoad else { return }
        guard !nextPage || hasMore else { return }
        if force { generation += 1; resetPages() }
        let requestGeneration = generation
        isLoading = true
        loadError = nil
        defer { if generation == requestGeneration { isLoading = false } }
        do {
            let client = try appState.currentMarmotClient()
            var result = try await client.marmot.attachmentHistoryPage(accountRef: accountRef,
                groupIdHex: groupIdHex, limit: 100, cursor: cursor)
            try Task.checkCancellation()
            guard generation == requestGeneration, appState.activeAccountRef == accountRef,
                  appState.client === client else { return }
            let mustRestart: Bool
            switch result {
            case .restartRequired, .cursorMismatch: mustRestart = true
            case .page(let page): mustRestart = version.map { page.version.changeSince(previous: $0) == .restartRequired } ?? false
            case .invalidLimit: mustRestart = false
            }
            if mustRestart {
                resetPages()
                result = try await client.marmot.attachmentHistoryPage(accountRef: accountRef,
                    groupIdHex: groupIdHex, limit: 100, cursor: nil)
                try Task.checkCancellation()
                guard generation == requestGeneration, appState.activeAccountRef == accountRef,
                      appState.client === client else { return }
            }
            switch result {
            case .page(let page):
                var ids = Set(items.map(\.id))
                items.append(contentsOf: GroupSharedMediaPresentation.items(entries: page.entries)
                    .filter { ids.insert($0.id).inserted })
                if version == nil { version = page.version }
                cursor = page.nextCursor
                hasMore = page.hasMore
                visualItems = GroupSharedMediaPresentation.visualItems(from: items)
                rebuildMonthSections()
                didLoad = true
            case .restartRequired, .cursorMismatch:
                resetPages()
                throw AttachmentReadError.stale
            case .invalidLimit:
                throw AttachmentReadError.unavailable
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            loadError = L10n.string("Couldn't load shared media.")
        }
    }

    func refreshVersion(groupIdHex: String, using appState: AppState) async {
        guard !isLoading, let previous = version, let account = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient() else { return }
        do {
            let current = try await client.marmot.attachmentHistoryVersion(accountRef: account, groupIdHex: groupIdHex)
            guard !Task.isCancelled, appState.activeAccountRef == account, appState.client === client else { return }
            switch current.changeSince(previous: previous) {
            case .unchanged: break
            case .restartRequired:
                await load(groupIdHex: groupIdHex, using: appState, force: true)
            case .additions:
                hasNewAttachments = true
            }
        } catch { /* The explicit refresh action surfaces read failures. */ }
    }

    private func resetPages() {
        cursor = nil
        version = nil
        items = []
        visualItems = []
        visualMonthSections = []
        hasMore = false
        hasNewAttachments = false
        didLoad = false
    }

    /// Pages message history newest-first and extracts links. The scan is
    /// bounded; when it stops early the truncation is surfaced, never silent.
    func loadLinks(groupIdHex: String, using appState: AppState, force: Bool = false) async {
        guard let accountRef = appState.activeAccountRef else { return }
        guard !isLoadingLinks, force || !didLoadLinks else { return }
        let requestGeneration = generation
        isLoadingLinks = true
        linksError = nil
        defer { if generation == requestGeneration { isLoadingLinks = false } }
        do {
            let client = try appState.currentMarmotClient()
            var scanned: [SharedMediaLibraryPresentation.LinkScanRecord] = []
            var before: UInt64?
            var beforeMessageId: String?
            var truncated = false
            while true {
                try Task.checkCancellation()
                let page = try await client.timelineMessages(
                    accountRef: accountRef,
                    query: TimelineMessageQueryFfi(
                        groupIdHex: groupIdHex,
                        search: nil,
                        before: before,
                        beforeMessageId: beforeMessageId,
                        after: nil,
                        afterMessageId: nil,
                        limit: Self.linkScanPageLimit
                    )
                )
                scanned.append(contentsOf: page.messages.map {
                    SharedMediaLibraryPresentation.LinkScanRecord(
                        messageIdHex: $0.messageIdHex,
                        kind: $0.kind,
                        content: $0.deleted ? "" : $0.plaintext,
                        timelineAt: $0.timelineAt
                    )
                })
                guard page.hasMoreBefore, let oldest = page.messages.last else { break }
                if scanned.count >= Self.linkScanMessageLimit {
                    truncated = true
                    break
                }
                let nextBefore = oldest.timelineAt
                let nextBeforeMessageId = oldest.messageIdHex
                if before == nextBefore, beforeMessageId == nextBeforeMessageId { break }
                before = nextBefore
                beforeMessageId = nextBeforeMessageId
            }
            try Task.checkCancellation()
            guard generation == requestGeneration, appState.activeAccountRef == accountRef,
                  appState.client === client else { return }
            links = SharedMediaLibraryPresentation.linkItems(from: scanned)
            linksTruncated = truncated
            didLoadLinks = true
        } catch is CancellationError {
            return
        } catch {
            linksError = L10n.string("Couldn't load links.")
        }
    }
}

/// Full shared-media library: media grid grouped by month, voice notes,
/// files, and links extracted from message history. Voice and link rows jump
/// to their message; files open into the share sheet.
struct SharedMediaLibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var conversation: ConversationViewModel

    @State private var model = SharedMediaLibraryViewModel()
    @State private var category = SharedMediaLibraryPresentation.Category.media
    @State private var gallery: MessageMediaGallery?
    @State private var loadingFileID: String?
    @State private var fileShare: SharedMediaFileShare?
    @State private var fileOpenError: String?
    @State private var linkToOpen: SharedMediaLibraryPresentation.LinkItem?
    @Environment(\.openURL) private var openURL

    private struct SharedMediaFileShare: Identifiable {
        let id = UUID()
        let url: URL
    }

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 64), spacing: 3),
        count: 3
    )

    init(
        conversation: ConversationViewModel,
        initialCategory: SharedMediaLibraryPresentation.Category = .media
    ) {
        self.conversation = conversation
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Shared media type", selection: $category) {
                Text("Media").tag(SharedMediaLibraryPresentation.Category.media)
                Text("Voice").tag(SharedMediaLibraryPresentation.Category.voice)
                Text("Files").tag(SharedMediaLibraryPresentation.Category.files)
                Text("Links").tag(SharedMediaLibraryPresentation.Category.links)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
            categoryContent
                .id(AttachmentPresentationState.shared.revision)
            if category != .links, model.hasNewAttachments {
                Button("Refresh") { Task { await refresh() } }
                    .disabled(model.isLoading)
            }
            if category != .links, model.hasMore {
                Button("Load more") {
                    Task { await model.load(groupIdHex: conversation.group.groupIdHex,
                        using: appState, nextPage: model.hasMore) }
                }
                .disabled(model.isLoading)
                .padding(12)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Shared Media")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .task(id: "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)") {
            await model.load(groupIdHex: conversation.group.groupIdHex, using: appState)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await model.refreshVersion(groupIdHex: conversation.group.groupIdHex, using: appState)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            model.rebuildMonthSections()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            model.rebuildMonthSections()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            // With "System" language selected the app-language notification
            // never fires for a region/calendar change; this one does.
            model.rebuildMonthSections()
        }
        .task(id: category) {
            if category == .links {
                await model.loadLinks(groupIdHex: conversation.group.groupIdHex, using: appState)
            }
        }
        .fullScreenCover(item: $gallery) { gallery in
            MessageMediaFullscreenGalleryView(
                gallery: gallery,
                onLoadMedia: mediaLoader,
                forwardingContext: MediaForwardingContext(
                    viewModel: conversation,
                    destinationProvider: { try await conversation.forwardDestinations() }
                ),
                onGoToMessage: { jumpToMessage($0) },
                onDismiss: { self.gallery = nil }
            )
        }
        .sheet(item: $fileShare) { share in
            ActivityShareSheet(items: [share.url])
        }
        .confirmationDialog(
            "Open this link?",
            isPresented: Binding(
                get: { linkToOpen != nil },
                set: { if !$0 { linkToOpen = nil } }
            ),
            titleVisibility: .visible,
            presenting: linkToOpen
        ) { link in
            Button("Open Link") {
                if let url = URL(string: link.urlString) {
                    openURL(url)
                }
                linkToOpen = nil
            }
            Button("Cancel", role: .cancel) { linkToOpen = nil }
        } message: { link in
            if link.hasInternationalizedHost {
                Text("\(link.display)\n\(L10n.string("This address uses international characters and may be misleading."))")
            } else {
                Text(link.display)
            }
        }
        .alert(
            "Couldn't open file",
            isPresented: Binding(
                get: { fileOpenError != nil },
                set: { if !$0 { fileOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { fileOpenError = nil }
        } message: {
            Text(fileOpenError ?? "")
        }
    }

    private var mediaLoader: ConversationMediaLoader {
        ConversationMediaLoader { media in
            try await conversation.data(for: media)
        }
    }

    // MARK: - Media

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .media:
            mediaContent
        case .voice:
            List { voiceSection }
                .listStyle(.insetGrouped)
                .refreshable { await refresh() }
        case .files:
            List { filesSection }
                .listStyle(.insetGrouped)
                .refreshable { await refresh() }
        case .links:
            List { linksSection }
                .listStyle(.insetGrouped)
                .refreshable { await refresh() }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        let visual = model.visualItems
        if model.isLoading && model.items.isEmpty {
            centeredStatus {
                ProgressView()
            }
        } else if let error = model.loadError, model.items.isEmpty {
            ContentUnavailableView {
                Label("Shared media unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await refresh() } }
            }
        } else if visual.isEmpty {
            ContentUnavailableView {
                Label(model.hasMore ? L10n.string("No photos or videos in loaded messages") : L10n.string("No photos or videos"),
                      systemImage: "photo.on.rectangle.angled")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.visualMonthSections) { section in
                        Text(section.title)
                            .font(.headline)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(section.items) { item in
                                GroupSharedMediaThumbnail(
                                    item: item.attachment,
                                    onLoadMedia: mediaLoader
                                ) { initialData in
                                    let attachments = visual.map(\.attachment)
                                    guard let gallery = MessageMediaGallery(
                                        items: attachments,
                                        initialItem: item.attachment,
                                        initialMediaData: initialData,
                                        messageIdByItemID: Dictionary(
                                            uniqueKeysWithValues: visual.compactMap { media in
                                                media.messageIdHex.map { (media.attachment.id, $0) }
                                            }
                                        )
                                    ) else { return }
                                    self.gallery = gallery
                                }
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                }
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
        }
    }

    private func centeredStatus<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() async {
        await model.load(groupIdHex: conversation.group.groupIdHex, using: appState, force: true)
        if category == .links {
            await model.loadLinks(groupIdHex: conversation.group.groupIdHex, using: appState, force: true)
        }
    }

    // MARK: - Voice

    @ViewBuilder
    private var voiceSection: some View {
        let voice = SharedMediaLibraryPresentation.voiceItems(from: model.items)
        if model.isLoading && model.items.isEmpty {
            loadingRow
        } else if let error = model.loadError, model.items.isEmpty {
            errorRow(error) {
                Task { await model.load(groupIdHex: conversation.group.groupIdHex, using: appState, force: true) }
            }
        } else if voice.isEmpty {
            emptyRow(title: model.hasMore ? "No audio in loaded messages" : "No voice messages", systemImage: "waveform")
        } else {
            Section {
                ForEach(voice) { item in
                    mediaRow(
                        item: item,
                        systemImage: "waveform",
                        title: L10n.string("Voice message")
                    )
                }
            }
        }
    }

    // MARK: - Files

    @ViewBuilder
    private var filesSection: some View {
        let files = SharedMediaLibraryPresentation.fileItems(from: model.items)
        if model.isLoading && model.items.isEmpty {
            loadingRow
        } else if let error = model.loadError, model.items.isEmpty {
            errorRow(error) {
                Task { await model.load(groupIdHex: conversation.group.groupIdHex, using: appState, force: true) }
            }
        } else if files.isEmpty {
            emptyRow(title: model.hasMore ? "No files in loaded messages" : "No files", systemImage: "doc")
        } else {
            Section {
                ForEach(files) { item in
                    mediaRow(
                        item: item,
                        systemImage: item.attachment.kind.systemImageName,
                        title: item.attachment.fileName
                    )
                }
            }
        }
    }

    /// Voice and file row: tap jumps to the message in the conversation; the
    /// trailing button downloads and shares the file.
    private func mediaRow(item: GroupSharedMediaItem, systemImage: String, title: String) -> some View {
        HStack(spacing: 12) {
            Button {
                jumpToMessage(item.messageIdHex)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(GroupSharedMediaPresentation.subtitle(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(item.messageIdHex == nil)

            Button {
                Task { await openFile(item) }
            } label: {
                if loadingFileID == item.id {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(loadingFileID != nil)
            .accessibilityLabel(L10n.formatted("Share %@", title))
        }
    }

    // MARK: - Links

    @ViewBuilder
    private var linksSection: some View {
        if model.isLoadingLinks && model.links.isEmpty {
            loadingRow
        } else if let error = model.linksError, model.links.isEmpty {
            errorRow(error) {
                Task {
                    await model.loadLinks(
                        groupIdHex: conversation.group.groupIdHex,
                        using: appState,
                        force: true
                    )
                }
            }
        } else if model.links.isEmpty {
            emptyRow(title: "No links yet", systemImage: "link")
        } else {
            Section {
                ForEach(model.links) { link in
                    HStack(spacing: 12) {
                        Button {
                            jumpToMessage(link.messageIdHex)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "link")
                                    .font(.callout)
                                    .foregroundStyle(.tint)
                                    .frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(link.display)
                                            .font(.callout)
                                            .lineLimit(2)
                                        if link.hasInternationalizedHost {
                                            Image(systemName: "exclamationmark.triangle")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                                .accessibilityLabel(L10n.string("This address uses international characters and may be misleading."))
                                        }
                                    }
                                    if link.timelineAt > 0 {
                                        Text(RelativeTime.short(
                                            Date(timeIntervalSince1970: TimeInterval(link.timelineAt))
                                        ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        Button {
                            linkToOpen = link
                        } label: {
                            Image(systemName: "safari")
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open Link")

                        ShareLink(item: link.urlString) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.formatted("Share %@", link.display))
                    }
                }
            } footer: {
                if model.linksTruncated {
                    Text(L10n.formatted(
                        "Links come from the most recent %lld messages.",
                        Int64(SharedMediaLibraryViewModel.linkScanMessageLimit)
                    ))
                }
            }
        }
    }

    // MARK: - Shared rows

    private var loadingRow: some View {
        Section {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 20)
        }
    }

    private func errorRow(_ message: String, retry: @escaping () -> Void) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
            Button("Retry", action: retry)
        }
    }

    private func emptyRow(title: LocalizedStringKey, systemImage: String) -> some View {
        Section {
            HStack(spacing: 8) {
                Spacer()
                Label(title, systemImage: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
                Spacer()
            }
        }
    }

    // MARK: - Actions

    /// Reopens the conversation targeted at the message; the pending-chat
    /// route resets the navigation path, so the library pops with it.
    private func jumpToMessage(_ messageIdHex: String?) {
        guard let messageIdHex, !messageIdHex.isEmpty else { return }
        appState.presentChat(
            groupIdHex: conversation.group.groupIdHex,
            messageIdHex: messageIdHex
        )
    }

    @MainActor
    private func openFile(_ item: GroupSharedMediaItem) async {
        guard loadingFileID == nil else { return }
        loadingFileID = item.id
        defer { loadingFileID = nil }
        do {
            let producerEpoch = MessageMediaCache.currentProducerEpoch()
            let data = try await mediaLoader.data(for: item.attachment)
            guard !Task.isCancelled,
                  let url = await MediaPlaybackFileStore.fileURL(
                    for: item.attachment,
                    data: data,
                    producerEpoch: producerEpoch
                  )
            else { return }
            fileShare = SharedMediaFileShare(url: url)
        } catch is CancellationError {
            return
        } catch {
            fileOpenError = UserFacingError.message(for: error)
        }
    }
}
