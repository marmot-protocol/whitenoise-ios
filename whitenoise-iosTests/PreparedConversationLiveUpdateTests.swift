import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct PreparedConversationLiveUpdateTests {
    @Test func preparedInstallationKeepsSendIdentityOrderAndUnchangedRowsInert() async throws {
        let client = try MarmotClient.testClient()
        try await client.startRuntime()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(45))
            Issue.record("Prepared-window fixture exceeded its deadline")
            try await client.marmot.shutdownAndClose()
        }
        defer { watchdog.cancel() }
        do {
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Prepared window", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
            var snapshot = try #require(window.snapshot())
            await window.cancel()
            let groupSubscription = try await client.subscribeGroupState(accountRef: account.label, groupIdHex: group.groupIdHex)
            let groupRecord = try #require(await client.groupStateSubscriptionSnapshot(groupSubscription))
            let state = AppState(client: client)
            let model = ConversationViewModel(appState: state, group: groupRecord)
            func record(_ id: String, _ time: UInt64, text: String = "OK") -> TimelineMessageRecordFfi {
                TimelineMessageRecordFfi(messageIdHex: id, sourceMessageIdHex: id, direction: "sent",
                    groupIdHex: group.groupIdHex, sender: account.accountIdHex, plaintext: text,
                    contentTokens: .emptyDocument, kind: MessageSemantics.kindChat, tags: [], timelineAt: time,
                    receivedAt: time, replyToMessageIdHex: nil, replyPreview: nil, mediaJson: nil, media: [],
                    agentTextStreamJson: nil, groupSystem: nil,
                    reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil, deleted: false,
                    deletedByMessageIdHex: nil, invalidationStatus: nil)
            }
            func install(_ records: [TimelineMessageRecordFfi], reactions: [String: ConversationReactionsFfi] = [:]) {
                snapshot.revision.sequence += 1
                snapshot.messages = records.map {
                    ConversationMessageFfi(timeline: $0, references: ConversationMessageReferencesFfi(
                        messageIdHex: $0.messageIdHex, sender: $0.sender, replyAuthor: nil, mentions: [],
                        mentionsTruncated: false, replyMentions: [], replyMentionsTruncated: false, system: nil,
                        reactions: reactions[$0.messageIdHex] ?? ConversationReactionsFfi(totalCount: 0, totalKinds: 0, items: [], omittedKinds: 0)))
                }
                model.installConversationWindow(snapshot)
            }
            var edited = record("edited", 90, text: "accepted body")
            edited.edit = TimelineEditSummaryFfi(editCount: 1, latestEditMessageIdHex: "edit-one", editedAt: 91)
            install([edited])
            #expect(model.isEdited("edited"))
            #expect(model.hasEditHistory("edited"))
            if case .message(let body, _) = model.timeline.first?.kind {
                #expect(body.plaintext == "accepted body")
            } else {
                Issue.record("Expected accepted edit to retain its message row")
            }
            edited.edit = nil
            edited.plaintext = "original body"
            install([edited])
            #expect(!model.isEdited("edited"))
            #expect(!model.hasEditHistory("edited"))
            let old = record("old", 100)
            let new = record("new", 1) // Protocol order intentionally disagrees with timestamps.
            let pending = ConversationViewModel.appMessageRecord(from: record("", 101))
            install([old])
            model.applyPendingOutgoingMessage(tempId: "one", record: pending)
            model.applyPendingOutgoingMessage(tempId: "two", record: pending)
            install([old])
            install([old])
            #expect(model.timeline.map(\.id) == ["msg:old", "msg:one", "msg:two"])
            // Projection arrives before callback. Without an ID the temporary row is not guessed away.
            install([old, new])
            model.confirmSent(tempId: "one", record: pending, messageId: "new")
            #expect(model.timeline.map(\.id) == ["msg:old", "msg:one", "msg:two"])
            #expect(model.protocolID(forDisplayID: "msg:one") == "new")
            #expect(model.protocolID(forDisplayID: "msg:two") == nil)
            install([old, new])
            #expect(model.timeline.map(\.id) == ["msg:old", "msg:one", "msg:two"])
            // Callback first; a stale retained window must not evict its local echo.
            model.confirmSent(tempId: "two", record: pending, messageId: "second")
            install([old, new])
            #expect(model.timeline.map(\.id) == ["msg:old", "msg:one", "msg:two"])
            let second = record("second", 0)
            install([old, new, second])
            #expect(model.timeline.map(\.id) == ["msg:old", "msg:one", "msg:two"])
            let generation = model.timelineStore.timelineProjectionGeneration
            let rebuilds = model.timelineStore.timelineRebuildCountForTesting
            snapshot.header.selected.title = .literal(text: "Header changed")
            snapshot.readState.lastReadMessageIdHex = "new"
            snapshot.draft = try await client.saveMessageDraftIfRevision(accountRef: account.label,
                revision: snapshot.draft.revision, snapshot: ConversationDraftSnapshot(
                    canonicalText: "unsent draft", replyToMessageIdHex: nil, mediaAttachments: []))
            install([old, new, second])
            #expect(model.timelineStore.timelineProjectionGeneration == generation)
            #expect(model.timelineStore.timelineRebuildCountForTesting == rebuilds)
            let tallies = ConversationReactionsFfi(totalCount: 1, totalKinds: 1,
                items: [.init(emoji: "👍", count: 1, reactors: ["peer"], viewerReacted: false)], omittedKinds: 0)
            install([old, new, second], reactions: ["new": tallies])
            #expect(model.reactions(for: "new").first?.count == 1)
            #expect(model.reactions(for: "old").isEmpty)
            #expect(model.timelineStore.timelineRebuildCountForTesting == rebuilds)
            snapshot.identities = [.init(accountIdHex: account.accountIdHex, displayName: "New name",
                avatar: snapshot.header.selected.avatar, hasCachedProfile: true, avatarAsset: nil)]
            install([old, new, second])
            #expect(model.windowDisplayName(for: account.accountIdHex) == "New name")
            let beforeAvatar = model.timelineStore.markdownProjections.buildCountForTesting
            snapshot.identities[0].avatarAsset = AvatarAssetFfi(target: "native-target", reference: "native-reference",
                availability: .ready, acquisition: nil, contentRevision: 1, byteCount: 40)
            install([old, new, second])
            #expect(model.windowIdentities[account.accountIdHex]?.avatarAsset?.contentRevision == 1)
            #expect(model.timelineStore.markdownProjections.buildCountForTesting == beforeAvatar)
            let markdownBuilds = model.timelineStore.markdownProjections.buildCountForTesting
            snapshot.identities.append(.init(accountIdHex: "unreferenced", displayName: "Unused",
                avatar: snapshot.header.selected.avatar, hasCachedProfile: true, avatarAsset: nil))
            install([old, new, second])
            #expect(model.timelineStore.markdownProjections.buildCountForTesting == markdownBuilds)
            // Once observed, a durable row follows bounded-window membership.
            install([old, second])
            #expect(model.timeline.map(\.id) == ["msg:old", "msg:two"])
            model.applyPendingOutgoingMessage(tempId: "accepted", record: pending)
            model.timelineStore.confirmSent(tempId: "accepted", record: pending, messageId: "accepted-id", published: false)
            #expect(model.timelineStore.undeliveredDurableMessageId(rowId: "msg:accepted") == "accepted-id")
            install([old, second])
            #expect(model.timeline.contains { $0.id == "msg:accepted" })
            var accepted = record("accepted-id", 3)
            accepted.sourceMessageIdHex = nil
            install([old, second, accepted])
            #expect(model.timeline.last?.id == "msg:accepted")
            if case .message(_, let status) = model.timeline.last?.kind { #expect(status == .sending) }
            accepted.sourceMessageIdHex = "source"
            install([old, second, accepted])
            if case .message(_, let status) = model.timeline.last?.kind { #expect(status == .sent) }
            accepted.invalidationStatus = "invalidated"
            install([old, second, accepted])
            if case .message(_, let status) = model.timeline.last?.kind { #expect(status == .failed) }
            // A late successful callback must not overwrite canonical invalidation.
            model.confirmSent(tempId: "accepted", record: pending, messageId: "accepted-id")
            if case .message(_, let status) = model.timeline.last?.kind { #expect(status == .failed) }
            model.applyPendingOutgoingMessage(tempId: "unknown", record: pending)
            model.timelineStore.acceptSend(tempId: "unknown", record: pending, summary: SendSummaryFfi(
                published: 0, messageIds: [], acceptDisposition: .completionUnknown, maintenanceDisposition: .ready))
            install([old, second, accepted])
            #expect(model.timelineStore.localSendPhase(rowID: "msg:unknown") == .completionUnknown)
            #expect(model.timelineStore.failedTransientRecord(rowId: "msg:unknown") == nil)
            model.applyPendingOutgoingMessage(tempId: "failure", record: pending)
            model.timelineStore.markFailed(tempId: "failure")
            #expect(model.timelineStore.failedTransientRecord(rowId: "msg:failure") != nil)
            model.timelineStore.discardTransientRow(rowId: "msg:failure")
            let media = MessageMediaAttachment(id: "local", reference: nil, fileName: "local.jpg",
                mediaType: "image/jpeg", dim: nil, localData: Data([1, 2, 3]))
            model.installPendingMediaForTesting(rowId: "msg:photo", items: [media])
            model.applyPendingOutgoingMessage(tempId: "photo", record: pending)
            model.confirmSent(tempId: "photo", record: pending, messageId: "photo-id")
            install([old, second, accepted])
            #expect(model.pendingMediaForTesting(rowId: "msg:photo") == [media])
            var photo = record("photo-id", 4, text: "")
            let reference = MediaAttachmentReferenceFfi(locators: [], ciphertextSha256: String(repeating: "a", count: 64),
                plaintextSha256: String(repeating: "b", count: 64), nonceHex: String(repeating: "c", count: 24),
                fileName: "canonical.jpg", mediaType: "image/jpeg", version: .v1, sourceEpoch: 1, dim: nil, thumbhash: nil)
            photo.media = [.accepted(attachmentIndex: 0, reference: reference)]
            install([old, second, accepted, photo])
            #expect(model.pendingMediaForTesting(rowId: "msg:photo") == nil)
            let photoRow = try #require(model.timeline.first { $0.id == "msg:photo" })
            #expect(model.mediaItems(for: photoRow).first?.fileName == "canonical.jpg")
            #expect(photo.tags.isEmpty)
            snapshot.hasMoreAfter = true
            install([old, second, accepted])
            model.reportConversationViewport(atTail: true, visibleRowID: "msg:two")
            #expect(model.viewportIntent == .history("second"))
            await model.returnConversationToLatest()
            #expect(model.viewportIntent == .followingLatest)
            model.reportConversationViewport(atTail: false, visibleRowID: "msg:old")
            #expect(model.viewportIntent == .history("old"))
            snapshot.hasMoreAfter = false
            install([old, second, accepted])
            await model.returnConversationToLatest()
            model.reportConversationViewport(atTail: true, visibleRowID: "msg:two")
            #expect(model.viewportIntent == .followingLatest)
            model.resetOptimisticStateForTesting()
            let fullWindow = (0..<200).map { record("retained-\($0)", UInt64($0)) }
            install(fullWindow)
            await model.returnConversationToLatest()
            model.reportConversationViewport(atTail: true, visibleRowID: "msg:retained-199")
            #expect(model.viewportIntent == .followingLatest)
            install(Array(fullWindow.dropFirst()) + [record("incoming", 200)])
            #expect(model.timeline.count == 200)
            #expect(model.timeline.last?.id == "msg:incoming")
            model.applyPendingOutgoingMessage(tempId: "tail-send", record: pending)
            model.confirmSent(tempId: "tail-send", record: pending, messageId: "tail-durable")
            install(Array(fullWindow.dropFirst(2)) + [record("incoming", 200), record("tail-durable", 201)])
            #expect(model.timeline.count == 200)
            #expect(model.timeline.last?.id == "msg:tail-send")
            model.resetOptimisticStateForTesting()
            model.confirmSent(tempId: "unknown", record: pending, messageId: "late")
            #expect(!model.timeline.contains { $0.id == "msg:unknown" })
            for index in 0..<TimelineStore.maximumLocalEchoes {
                model.applyPendingOutgoingMessage(tempId: "bounded-\(index)", record: pending)
            }
            #expect(!model.timelineStore.canStageOutgoingMessage)
            model.timelineStore.discardTransientRow(rowId: "msg:bounded-0")
            #expect(model.timelineStore.canStageOutgoingMessage)
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func preparedReactionOverlayUsesViewerFlagEvenOutsideReactorPreview() {
        let cache = ConversationReactionProjectionCache()
        let value = ConversationReactionsFfi(totalCount: 35, totalKinds: 2, items: [ConversationReactionFfi(
            emoji: "👍", count: 30, reactors: ["someone"], viewerReacted: true)], omittedKinds: 1)
        cache.insertRemoval(ReactionRemoval(targetMessageIdHex: "target", emoji: "👍", sender: "me"))
        let effective = cache.preparedDetails(value, target: "target", me: "me")
        #expect(effective.groups.first?.count == 29)
        #expect(effective.groups.first?.mine == false)
        #expect(effective.totalReactionCount == 34)
        var updated = value
        updated.items[0].viewerReacted = false
        updated.items[0].count = 29
        updated.totalCount = 34
        cache.installPrepared(updated, target: "target", me: "me")
        #expect(!cache.hasOptimistic)
        #expect(cache.preparedDetails(updated, target: "target", me: "me").totalReactionCount == 34)
    }

    @Test func canonicalOrderCanRevisitCalendarDayWithoutDuplicateSectionIDs() {
        let cache = ConversationDaySectionProjectionCache()
        let rows = [TimelineItem.systemEvent(id: "one", event: .groupCreated, timestamp: 1),
                    TimelineItem.systemEvent(id: "two", event: .groupCreated, timestamp: 200_000),
                    TimelineItem.systemEvent(id: "three", event: .groupCreated, timestamp: 2)]
        let sections = cache.sections(for: rows, generation: 1)
        #expect(sections.flatMap(\.items) == rows)
        #expect(Set(sections.map(\.id)).count == 3)
    }
}
