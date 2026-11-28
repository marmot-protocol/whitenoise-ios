import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

/// Presented chat-list updates reach chats this screen lists, so avatars that
/// finish acquiring and renamed chats show without leaving the screen.
@MainActor
struct ManageStorageModelTests {
    private static let readyAsset = AvatarAssetFfi(target: "avatar-target", reference: "avatar-ref",
                                                   availability: .ready, acquisition: nil,
                                                   contentRevision: 2, byteCount: 512)

    private static func model(chats: [String], attachmentChats: [String] = []) -> ManageStorageModel {
        ManageStorageModel.fixture(
            usage: storageUsage(),
            chats: chats.map { (chatUsage($0), "Before") },
            attachments: attachmentChats.map(retainedAttachment)
        )
    }

    fileprivate static func presented(_ groupIdHex: String, title: String, asset: AvatarAssetFfi?,
                                  pending: Bool = false) -> PresentedChatRowFfi {
        let row = ChatListRowFfi(
            groupIdHex: groupIdHex, pinned: false, pinnedPosition: nil, archived: false,
            pendingConfirmation: pending, title: "", groupName: "", avatarUrl: nil, avatar: nil,
            lastMessage: nil, unreadCount: 0, hasUnread: false, manuallyMarkedUnread: false,
            unreadMentionCount: 0, unreadMention: false, firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil, lastReadTimelineAt: nil, conversationCreatedAt: 1,
            activitySortAt: 1, updatedAt: 1, selfMembership: .member, conversationKind: .group,
            muted: false, mutedUntilMs: nil, leaveRequestPending: false, leaveRequestedAtMs: nil
        )
        let presentation = ConversationPresentationFfi(
            title: .literal(text: title), avatar: .placeholder(stableSeed: "seed-\(groupIdHex)", source: .group),
            titleSource: .group, avatarSource: .group, peerId: nil, resolution: .lastKnown
        )
        return PresentedChatRowFfi(row: row, presentation: presentation, avatarAsset: asset)
    }

    @Test func updatesRefreshTitlesAndAvatarsOfListedChats() {
        let model = Self.model(chats: ["listed"])
        #expect(model.identity(for: "listed").avatarAsset == nil)

        model.applyPresentedRows([Self.presented("listed", title: "Renamed", asset: Self.readyAsset)],
                                 using: AppState.test())

        #expect(model.identity(for: "listed").title == "Renamed")
        #expect(model.identity(for: "listed").avatarAsset == Self.readyAsset)
    }

    @Test func chatsOnlyInAnAttachmentListAreRefreshedToo() {
        let model = Self.model(chats: [], attachmentChats: ["from-attachment"])
        model.applyPresentedRows([Self.presented("from-attachment", title: "Hiking", asset: nil)],
                                 using: AppState.test())
        #expect(model.identity(for: "from-attachment").title == "Hiking")
    }

    /// Rows for chats this screen does not list are ignored, so no avatar is
    /// requested for anything off screen.
    @Test func unlistedChatsAreIgnored() {
        let model = Self.model(chats: ["listed"])
        model.applyPresentedRows([Self.presented("elsewhere", title: "Elsewhere", asset: Self.readyAsset)],
                                 using: AppState.test())
        #expect(model.identity(for: "elsewhere").title == L10n.string("Conversation unavailable"))
        #expect(model.identity(for: "elsewhere").avatarAsset == nil)
    }

    @Test func pendingInvitationsKeepAvatarEgressSuppressed() {
        let model = Self.model(chats: ["invite"])
        model.applyPresentedRows([Self.presented("invite", title: "Invite", asset: Self.readyAsset, pending: true)],
                                 using: AppState.test())
        #expect(model.identity(for: "invite").title == "Invite")
        #expect(model.identity(for: "invite").avatarAsset == nil)
    }
}

/// Removals drop the host's decrypted copies of what MDK removed, and no more.
@MainActor
struct ManageStorageRemovalTests {
    /// Only bulk removals, which report a count, drop every profile's decrypted
    /// copies; a single Remove drops just its own file, and Clear Cache none.
    @Test func onlyBulkRemovalsDropEveryDecryptedCopy() {
        #expect(ManageStorageModel.Operation.removeOlder(.account).removesInBulk)
        #expect(ManageStorageModel.Operation.removeOlder(.chat("g")).removesInBulk)
        #expect(ManageStorageModel.Operation.removeChat("g").removesInBulk)
        #expect(ManageStorageModel.Operation.keepMedia.removesInBulk)
        #expect(!ManageStorageModel.Operation.removeAttachment("g:m:s:0").removesInBulk)
        #expect(!ManageStorageModel.Operation.clearCache.removesInBulk)
    }

    /// A longer Keep Media window removes nothing, so open chats keep their decrypted copies.
    @Test func bulkRemovalsThatRemovedNothingKeepDecryptedCopies() {
        let keepMedia = ManageStorageModel.Operation.keepMedia
        #expect(!keepMedia.dropsEveryDecryptedCopy(removed: 0))
        #expect(keepMedia.dropsEveryDecryptedCopy(removed: 3))
        // A failed call may still have removed some.
        #expect(keepMedia.dropsEveryDecryptedCopy(removed: nil))
        #expect(!ManageStorageModel.Operation.removeChat("g").dropsEveryDecryptedCopy(removed: 0))
        #expect(!ManageStorageModel.Operation.clearCache.dropsEveryDecryptedCopy(removed: nil))
    }

    /// The removed file's decrypted copy is found by its original message, source and slot.
    @Test func singleRemovalNamesTheRemovedFilesPlaintext() {
        func reference(_ plaintext: Character) -> MediaAttachmentReferenceFfi {
            MediaAttachmentReferenceFfi(locators: [], ciphertextSha256: String(repeating: "a", count: 64),
                plaintextSha256: String(repeating: plaintext, count: 64), nonceHex: String(repeating: "c", count: 24),
                fileName: "photo.jpg", mediaType: "image/jpeg", version: .v1, sourceEpoch: 1, dim: nil, thumbhash: nil)
        }
        func entry(message: String, source: String, _ attachment: MediaAttachmentOutcomeFfi) -> AttachmentEntryFfi {
            AttachmentEntryFfi(messageIdHex: message, sourceMessageIdHex: source, sender: "sender", timelineAt: 1,
                               receivedAt: 1, sourceEpoch: nil, category: .image, role: .shared, attachment: attachment)
        }
        let target = AttachmentLocalTargetFfi(messageIdHex: "edit", sourceMessageIdHex: "original", attachmentIndex: 2)
        let rejected = MediaAttachmentRejectionFfi(kind: .unsupportedFormat, detail: "bad")
        let entries = [
            entry(message: "edit", source: "other", .accepted(attachmentIndex: 2, reference: reference("1"))),
            entry(message: "other", source: "original", .accepted(attachmentIndex: 2, reference: reference("2"))),
            entry(message: "edit", source: "original", .rejected(attachmentIndex: 2, rejection: rejected)),
            entry(message: "edit", source: "original", .accepted(attachmentIndex: 1, reference: reference("3"))),
            entry(message: "edit", source: "original", .accepted(attachmentIndex: 2, reference: reference("4"))),
        ]

        #expect(MarmotClient.plaintextHash(in: entries, for: target) == String(repeating: "4", count: 64))
        #expect(MarmotClient.plaintextHash(in: Array(entries.dropLast()), for: target) == nil)
    }
}

/// Listings read page by page from the profile and runtime they started on,
/// and start over whenever either changes or something is removed.
@MainActor
struct ManageStorageListingTests {
    @Test func listingFollowsMDKsCursorAndStopsAfterTheLastPage() async {
        let runtime = StorageRuntimeStub()
        let last = ChatStoragePageFfi(chats: [chatUsage("second")], nextCursor: nil)
        let first = ChatStoragePageFfi(chats: [chatUsage("first")], nextCursor: ChatStorageCursor(noPointer: .init()))
        runtime.chatPages = [first, last]
        runtime.titles = ["first": "Hiking", "second": "Book Club"]
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()

        await model.bind(using: appState)
        #expect(model.chats.items.map(\.groupIdHex) == ["first"])
        #expect(model.identity(for: "first").title == "Hiking")
        #expect(model.usage != nil)
        #expect(model.keepMedia == .forever)

        await model.loadMoreChats(using: appState)
        await model.loadMoreChats(using: appState)

        #expect(model.chats.items.map(\.groupIdHex) == ["first", "second"])
        #expect(model.identity(for: "second").title == "Book Club")
        #expect(runtime.chatReads.count == 2)
        #expect(runtime.chatReads.first! == nil)
        #expect(runtime.chatReads.last! === first.nextCursor)
    }

    enum Change: CaseIterable { case profileSwitched, runtimeRebuilt, runtimeSuspended }

    /// A page MDK returns after the screen's profile or runtime changed belongs
    /// to another listing, so it never lands in this one.
    @Test(arguments: Change.allCases)
    func aPageReadBeforeAChangeIsDropped(_ change: Change) async {
        let runtime = StorageRuntimeStub()
        runtime.chatPages = [ChatStoragePageFfi(chats: [chatUsage("old")], nextCursor: nil)]
        let gate = AsyncTestCheckpoint()
        runtime.chatsGate = gate
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()

        let binding = Task { await model.bind(using: appState) }
        await gate.waitUntilPaused()
        switch change {
        case .profileSwitched: appState.activeAccountRef = "other"
        case .runtimeRebuilt: runtime.generation += 1
        case .runtimeSuspended: runtime.available = false
        }
        await gate.release()
        await binding.value

        #expect(model.chats.items.isEmpty)
        #expect(!model.chatsFailed)
        #expect(!model.isLoadingChats)
        #expect(runtime.presentedRowReads.isEmpty)
    }

    @Test func aRemovalStartsEveryListingOverAndDropsPagesReadBeforeIt() async {
        let runtime = StorageRuntimeStub()
        runtime.chatPages = [ChatStoragePageFfi(chats: [chatUsage("chat")], nextCursor: nil)]
        runtime.attachmentPages = [RetainedAttachmentsPageFfi(attachments: [retainedAttachment("chat")],
                                                              nextCursor: nil)]
        let gate = AsyncTestCheckpoint()
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)
        let epoch = model.epoch

        runtime.attachmentsGate = gate
        let loading = Task { await model.loadMoreAttachments(.chat("chat"), using: appState) }
        await gate.waitUntilPaused()
        await model.removeAllAttachments(inChat: "chat", using: appState)
        await gate.release()
        await loading.value

        #expect(model.epoch > epoch)
        #expect(model.attachmentPages(.chat("chat")).items.isEmpty)
        #expect(model.attachmentPages(.chat("chat")).hasMore)
        #expect(runtime.chatReads.count == 2)
        #expect(runtime.chatReads.allSatisfy { $0 == nil })
        #expect(model.chats.items.map(\.groupIdHex) == ["chat"])
    }

    /// Each scope pages on its own: a failure marks only its own listing, and
    /// the account-wide one names the chats it lists.
    @Test func attachmentListingsArePerScope() async {
        let runtime = StorageRuntimeStub()
        runtime.attachmentPages = [RetainedAttachmentsPageFfi(attachments: [retainedAttachment("chat")],
                                                              nextCursor: nil)]
        runtime.titles = ["chat": "Hiking"]
        runtime.failingAttachmentScopes = ["broken"]
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)

        await model.loadMoreAttachments(.account, using: appState)
        await model.loadMoreAttachments(.chat("broken"), using: appState)

        #expect(model.attachmentPages(.account).items.map(\.groupIdHex) == ["chat"])
        #expect(model.identity(for: "chat").title == "Hiking")
        #expect(model.attachmentsFailed == [.chat("broken")])
        #expect(runtime.attachmentReads == [nil, "broken"])
    }

    @Test func aFailedPageIsShownAndRetriedFromTheSameCursor() async {
        let runtime = StorageRuntimeStub()
        runtime.chatPages = [ChatStoragePageFfi(chats: [chatUsage("chat")], nextCursor: nil)]
        runtime.failingChatReads = 1
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()

        await model.bind(using: appState)
        #expect(model.chatsFailed)
        #expect(model.chats.items.isEmpty)

        await model.loadMoreChats(using: appState)
        #expect(!model.chatsFailed)
        #expect(model.chats.items.map(\.groupIdHex) == ["chat"])
        #expect(runtime.chatReads.count == 2)
        #expect(runtime.chatReads.allSatisfy { $0 == nil })
    }
}

/// Removals report MDK's count and drop the host's decrypted copies of what
/// MDK removed, and no more.
@MainActor
struct ManageStorageRemovalRunTests {
    @Test func keepMediaReportsMDKsCountAndShowsTheSavedWindow() async {
        let runtime = StorageRuntimeStub()
        runtime.keepMediaRemoves = .success(4)
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)
        runtime.keepMediaRead = .failure(StorageStubError.failed)

        let removed = await model.setKeepMedia(.thirtyDays, using: appState)

        #expect(removed == 4)
        #expect(runtime.keepMediaSets == [.thirtyDays])
        // Saved, so the window stands although reading it back failed.
        #expect(model.keepMedia == .thirtyDays)
        #expect(model.failedOperation == nil)
        #expect(runtime.purges == 1)
        #expect(runtime.changesEnded == runtime.changesBegun)
    }

    @Test func aKeepMediaChangeThatOutlivesItsProfileReportsNoCount() async {
        let runtime = StorageRuntimeStub()
        runtime.keepMediaRemoves = .success(4)
        let gate = AsyncTestCheckpoint()
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)

        runtime.keepMediaGate = gate
        let change = Task { await model.setKeepMedia(.thirtyDays, using: appState) }
        await gate.waitUntilPaused()
        appState.activeAccountRef = "other"
        await gate.release()

        #expect(await change.value == nil)
        #expect(model.keepMedia == .forever)
        #expect(model.failedOperation == nil)
        #expect(runtime.changesEnded == runtime.changesBegun)
    }

    enum Outcome: CaseIterable { case removedSome, removedNone, failed }

    /// A bulk removal can't name what it removed, so any that may have removed
    /// something drops every decrypted copy; one that reported none keeps them.
    @Test(arguments: Outcome.allCases)
    func bulkRemovalDropsDecryptedMediaWhenMDKMayHaveRemovedSome(_ outcome: Outcome) async {
        let runtime = StorageRuntimeStub()
        runtime.removeChatResult = switch outcome {
        case .removedSome: .success(2)
        case .removedNone: .success(0)
        case .failed: .failure(StorageStubError.failed)
        }
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)

        await model.removeAllAttachments(inChat: "chat", using: appState)

        #expect(runtime.removedChats == ["chat"])
        #expect(runtime.purges == (outcome == .removedNone ? 0 : 1))
        let failed: ManageStorageModel.Operation? = outcome == .failed ? .removeChat("chat") : nil
        #expect(model.failedOperation == failed)
        #expect(model.operation == nil)
        #expect(runtime.changesEnded == runtime.changesBegun)
    }

    /// MDK removes exactly what the confirmation named: its cutoff, in its scope.
    @Test(arguments: [ManageStorageModel.Scope.account, .chat("chat")])
    func removeOlderPassesTheConfirmedCutoffAndScope(_ scope: ManageStorageModel.Scope) async {
        let runtime = StorageRuntimeStub()
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)
        let cutoff = ManageStoragePresentation.RemovalCutoff(age: .oneMonth, now: Date(timeIntervalSince1970: 1e9),
                                                             calendar: Calendar(identifier: .gregorian))

        await model.removeOlder(than: cutoff, in: scope, using: appState)

        #expect(runtime.olderRemovals.count == 1)
        #expect(runtime.olderRemovals.first?.receivedBefore == cutoff.receivedBefore)
        #expect(runtime.olderRemovals.first?.groupIdHex == scope.groupIdHex)
        #expect(model.failedOperation == nil)
    }

    @Test func aRemovalTheRuntimeRefusesRemovesNothing() async {
        let runtime = StorageRuntimeStub()
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)
        runtime.refusesChanges = true

        await model.removeAllAttachments(inChat: "chat", using: appState)

        #expect(runtime.removedChats.isEmpty)
        #expect(runtime.purges == 0)
        #expect(model.failedOperation == .removeChat("chat"))
    }

    @Test func removingOneAttachmentDropsOnlyItsOwnDecryptedCopy() async {
        let runtime = StorageRuntimeStub()
        runtime.plaintextHash = "hash"
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)

        await model.remove(retainedAttachment("chat"), using: appState)

        #expect(runtime.droppedHashes == ["hash"])
        #expect(runtime.purges == 0)
        #expect(model.failedOperation == nil)
    }

    /// An entry that no longer reads locally is already gone: nothing to drop.
    @Test func removingAnAttachmentThatIsAlreadyGoneDropsNothing() async {
        let runtime = StorageRuntimeStub()
        runtime.removesAttachment = false
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)
        let attachment = retainedAttachment("chat")

        await model.remove(attachment, using: appState)

        #expect(runtime.droppedHashes.isEmpty)
        #expect(runtime.purges == 0)
        #expect(model.failedOperation == .removeAttachment(ManageStoragePresentation.attachmentID(attachment)))
    }

    @Test func oneChangeRunsAtATime() async {
        let runtime = StorageRuntimeStub()
        runtime.removeChatResult = .success(1)
        let gate = AsyncTestCheckpoint()
        let model = ManageStorageModel(dependencies: runtime.dependencies)
        let appState = runtime.appState()
        await model.bind(using: appState)

        runtime.removeChatGate = gate
        let removing = Task { await model.removeAllAttachments(inChat: "chat", using: appState) }
        await gate.waitUntilPaused()
        await model.clearCache(using: appState)
        #expect(model.operation == .removeChat("chat"))
        await gate.release()
        await removing.value

        #expect(runtime.avatarCacheClears == 0)
        #expect(runtime.changesBegun == 1)
        #expect(model.operation == nil)
    }
}

private enum StorageStubError: Error { case failed }

private func storageUsage() -> AttachmentStorageUsageFfi {
    AttachmentStorageUsageFfi(mediaBytes: 0, legacyBytes: 0, attachmentCount: 0, databaseBytes: 0,
                              databaseFreeBytes: 0, migration: .notNeeded, migrationBytes: 0, cacheBytes: 0)
}

private func chatUsage(_ groupIdHex: String) -> ChatAttachmentUsageFfi {
    ChatAttachmentUsageFfi(groupIdHex: groupIdHex, bytes: 1, attachmentCount: 1)
}

private func retainedAttachment(_ groupIdHex: String) -> RetainedAttachmentSummaryFfi {
    RetainedAttachmentSummaryFfi(
        groupIdHex: groupIdHex,
        target: AttachmentLocalTargetFfi(messageIdHex: "m-\(groupIdHex)", sourceMessageIdHex: "m-\(groupIdHex)",
                                         attachmentIndex: 0),
        byteCount: 1, mediaType: "image/jpeg", fileName: "", receivedAt: 1
    )
}

/// Stands in for the active profile's MDK runtime. Pages are served by the
/// cursor the model passes; a gate holds the next call of its kind once.
@MainActor
private final class StorageRuntimeStub {
    var available = true
    var generation = 0
    var refusesChanges = false
    var chatPages = [ChatStoragePageFfi(chats: [], nextCursor: nil)]
    var attachmentPages = [RetainedAttachmentsPageFfi(attachments: [], nextCursor: nil)]
    var titles: [String: String] = [:]
    var failingChatReads = 0
    var failingAttachmentScopes: Set<String> = []
    var keepMediaRead: Result<AttachmentKeepMediaFfi, Error> = .success(.forever)
    var keepMediaRemoves: Result<UInt64, Error> = .success(0)
    var removeChatResult: Result<UInt64, Error> = .success(0)
    var removesAttachment = true
    var plaintextHash: String?
    var chatsGate: AsyncTestCheckpoint?
    var attachmentsGate: AsyncTestCheckpoint?
    var keepMediaGate: AsyncTestCheckpoint?
    var removeChatGate: AsyncTestCheckpoint?

    private(set) var chatReads: [ChatStorageCursor?] = []
    private(set) var presentedRowReads: [String] = []
    private(set) var attachmentReads: [String?] = []
    private(set) var olderRemovals: [(receivedBefore: UInt64, groupIdHex: String?)] = []
    private(set) var keepMediaSets: [AttachmentKeepMediaFfi] = []
    private(set) var removedChats: [String] = []
    private(set) var avatarCacheClears = 0
    private(set) var droppedHashes: [String?] = []
    private(set) var purges = 0
    private(set) var changesBegun = 0
    private(set) var changesEnded = 0

    func appState() -> AppState {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        return appState
    }

    var dependencies: ManageStorageModel.Dependencies {
        ManageStorageModel.Dependencies(
            runtime: { appState in
                guard self.available, let accountRef = appState.activeAccountRef else { return nil }
                return .init(accountRef: accountRef, generation: self.generation, id: ObjectIdentifier(self),
                             calls: self.calls)
            },
            beginChange: { _ in
                if self.refusesChanges { throw ForegroundRuntimeMutationError.runtimeUnavailable }
                self.changesBegun += 1
                return .init(runtimeID: ObjectIdentifier(self), calls: self.calls, end: { self.changesEnded += 1 })
            },
            dropDecryptedCopy: { self.droppedHashes.append($0) },
            dropAllDecryptedMedia: { self.purges += 1 }
        )
    }

    private var calls: ManageStorageCalls {
        ManageStorageCalls(
            usage: { _ in storageUsage() },
            keepMedia: { _ in try self.keepMediaRead.get() },
            chats: { _, _, cursor in
                self.chatReads.append(cursor)
                await self.take(\.chatsGate)?.pause()
                if self.failingChatReads > 0 {
                    self.failingChatReads -= 1
                    throw StorageStubError.failed
                }
                return Self.page(after: cursor, in: self.chatPages, next: \.nextCursor)
            },
            attachments: { _, groupIdHex, _, cursor in
                self.attachmentReads.append(groupIdHex)
                await self.take(\.attachmentsGate)?.pause()
                if let groupIdHex, self.failingAttachmentScopes.contains(groupIdHex) { throw StorageStubError.failed }
                return Self.page(after: cursor, in: self.attachmentPages, next: \.nextCursor)
            },
            presentedRow: { _, groupIdHex in
                self.presentedRowReads.append(groupIdHex)
                return self.titles[groupIdHex].map {
                    ManageStorageModelTests.presented(groupIdHex, title: $0, asset: nil)
                }
            },
            openPresentedRows: { _ in throw CancellationError() },
            presentedRowsSnapshot: { _ in nil },
            clearAvatarCache: { _ in self.avatarCacheClears += 1 },
            removeOlder: { _, receivedBefore, groupIdHex in
                self.olderRemovals.append((receivedBefore, groupIdHex))
                return 0
            },
            setKeepMedia: { _, keep in
                self.keepMediaSets.append(keep)
                await self.take(\.keepMediaGate)?.pause()
                return try self.keepMediaRemoves.get()
            },
            removeChat: { _, groupIdHex in
                self.removedChats.append(groupIdHex)
                await self.take(\.removeChatGate)?.pause()
                return try self.removeChatResult.get()
            },
            removeAttachment: { _, _, _ in self.removesAttachment },
            plaintextHash: { _, _, _ in self.plaintextHash }
        )
    }

    private func take(_ gate: ReferenceWritableKeyPath<StorageRuntimeStub, AsyncTestCheckpoint?>)
        -> AsyncTestCheckpoint? {
        defer { self[keyPath: gate] = nil }
        return self[keyPath: gate]
    }

    /// The first page for no cursor, otherwise the page after the one that gave it.
    private static func page<Page, Cursor: AnyObject>(after cursor: Cursor?, in pages: [Page],
                                                      next: (Page) -> Cursor?) -> Page {
        guard let cursor else { return pages[0] }
        guard let index = pages.firstIndex(where: { next($0) === cursor }), index + 1 < pages.count else {
            Issue.record("read with a cursor no page gave")
            return pages[pages.count - 1]
        }
        return pages[index + 1]
    }
}
