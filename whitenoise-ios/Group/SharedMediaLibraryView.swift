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
    private var linkRequest: UUID?
    var isLoadingLinks: Bool { linkRequest != nil }
    private(set) var linksTruncated = false
    var loadError: String?
    var linksError: String?
    private var pager = AttachmentHistoryPager()
    var hasMore: Bool { didLoad && pager.canLoadMore }
    private(set) var hasNewAttachments = false
    private(set) var scope: AttachmentHistoryPager.Scope?
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
        guard let newScope = AttachmentHistoryPager.Scope(appState: appState, group: groupIdHex) else {
            if let owner = AttachmentHistoryPager.Scope(ownerOf: appState, group: groupIdHex), scope == owner { return }
            generation += 1
            scope = nil
            resetPages()
            loadError = nil
            resetLinks()
            if appState.activeAccountRef == nil {
                loadError = L10n.string("Couldn't load shared media.")
                linksError = L10n.string("Couldn't load links.")
            }
            isLoading = appState.activeAccountRef != nil
            return
        }

        if scope != newScope {
            generation += 1
            scope = newScope
            isLoading = false
            resetPages()
            resetLinks()
        }
        guard !isLoading || force, force || nextPage || !didLoad else { return }
        guard !nextPage || hasMore else { return }
        if force { generation += 1; resetPages() }
        let requestGeneration = generation
        isLoading = true
        loadError = nil
        defer { if generation == requestGeneration { isLoading = false } }
        do {
            var hops = 0
            while true {
                let (page, next) = try await pager.readNext(in: newScope, using: appState,
                    isCurrent: { self.generation == requestGeneration }, onRestart: { self.resetPages() })
                guard generation == requestGeneration, (try? newScope.currentClient(in: appState)) != nil else { return }
                pager = next
                if GroupSharedMediaPresentation.shouldReadPastFilteredPage(
                    galleryEntryCount: GroupSharedMediaPresentation.galleryEntries(page.entries).count,
                    hasMore: next.canLoadMore
                ), hops < GroupSharedMediaPresentation.maxFilteredPageHops {
                    hops += 1
                    continue
                }
                var ids = Set(items.map(\.id))
                items.append(contentsOf: GroupSharedMediaPresentation.items(entries: page.entries)
                    .filter { ids.insert($0.id).inserted })
                visualItems = GroupSharedMediaPresentation.visualItems(from: items)
                rebuildMonthSections()
                didLoad = true
                break
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            loadError = L10n.string("Couldn't load shared media.")
        }
    }

    func refreshVersion(groupIdHex: String, using appState: AppState) async {
        guard !isLoading, let previous = pager.baseline, let scope, scope.group == groupIdHex else { return }
        let ticket = generation
        do {
            let current = try await scope.version(in: appState)
            guard ticket == generation, self.scope == scope else { return }
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
        pager = .init()
        items = []
        visualItems = []
        visualMonthSections = []
        hasNewAttachments = false
        didLoad = false
    }

    private func resetLinks() {
        linkRequest = nil
        links = []
        linksError = nil
        linksTruncated = false
        didLoadLinks = false
    }

    /// Pages message history newest-first and extracts links. The scan is
    /// bounded; when it stops early the truncation is surfaced, never silent.
    func loadLinks(groupIdHex: String, using appState: AppState, force: Bool = false, enteringTab: Bool = false) async {
        guard let scope, scope == AttachmentHistoryPager.Scope(appState: appState, group: groupIdHex),
              enteringTab || !isLoadingLinks, force || !didLoadLinks else { return }
        let request = UUID()
        linkRequest = request
        linksError = nil
        defer { if linkRequest == request { linkRequest = nil } }
        do {
            let client = try scope.currentClient(in: appState)
            var scanned: [SharedMediaLibraryPresentation.LinkScanRecord] = []
            var before: UInt64?
            var beforeMessageId: String?
            var truncated = false
            while true {
                try Task.checkCancellation()
                let page = try await client.timelineMessages(
                    accountRef: scope.account,
                    query: TimelineMessageQueryFfi(
                        groupIdHex: groupIdHex,
                        search: nil,
                        sender: nil,
                        since: nil,
                        until: nil,
                        cursorGroupId: nil,
                        before: before,
                        beforeMessageId: beforeMessageId,
                        after: nil,
                        afterMessageId: nil,
                        limit: Self.linkScanPageLimit
                    )
                )
                _ = try scope.currentClient(in: appState)
                guard linkRequest == request else { return }
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
            links = SharedMediaLibraryPresentation.linkItems(from: scanned)
            linksTruncated = truncated
            didLoadLinks = true
        } catch is CancellationError {
            return
        } catch {
            guard linkRequest == request, scope == AttachmentHistoryPager.Scope(appState: appState, group: groupIdHex) else { return }
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
    @State private var fileShare: AttachmentShareFile?
    @State private var fileOpenError: String?
    @State private var linkToOpen: SharedMediaLibraryPresentation.LinkItem?
    @Environment(\.openURL) private var openURL

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
        let scope = AttachmentHistoryPager.Scope(appState: appState, group: conversation.group.groupIdHex)
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
        .task(id: scope) {
            await model.load(groupIdHex: conversation.group.groupIdHex, using: appState)
            guard scope != nil else { return }
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
        .task(id: category == .links ? model.scope : nil) {
            guard category == .links, model.scope == scope, scope != nil else { return }
            await model.loadLinks(groupIdHex: conversation.group.groupIdHex, using: appState, enteringTab: true)
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
            ActivityShareSheet(items: [share.url], onComplete: share.finish)
                .onDisappear(perform: share.finish)
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
        } openHandoff: { media, control in
            try await conversation.openHandoff(for: media, control: control)
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
        if (model.isLoadingLinks || (model.scope == nil && model.isLoading)) && model.links.isEmpty {
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
            fileShare = try await mediaLoader.shareFile(for: item.attachment, control: MediaFileTransferControlFfi())
        } catch is CancellationError {
            return
        } catch AttachmentHandoffFailure.storageFull {
            return
        } catch {
            fileOpenError = UserFacingError.message(for: error)
        }
    }
}
