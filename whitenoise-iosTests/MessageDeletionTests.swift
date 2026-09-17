import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct MessageDeletionTests {
    @Test func capabilityCoversOwnershipRoleAndConversationType() {
        struct Row {
            let name: String
            let isDirect: Bool
            let isMine: Bool
            let isAdmin: Bool
            let expectedForMe: Bool
            let expectedForEveryone: Bool
        }

        let rows = [
            Row(name: "own direct", isDirect: true, isMine: true, isAdmin: false, expectedForMe: true, expectedForEveryone: true),
            Row(name: "other direct", isDirect: true, isMine: false, isAdmin: false, expectedForMe: true, expectedForEveryone: false),
            Row(name: "other direct admin", isDirect: true, isMine: false, isAdmin: true, expectedForMe: true, expectedForEveryone: false),
            Row(name: "own group", isDirect: false, isMine: true, isAdmin: false, expectedForMe: true, expectedForEveryone: true),
            Row(name: "other group admin", isDirect: false, isMine: false, isAdmin: true, expectedForMe: true, expectedForEveryone: true),
            Row(name: "other group member", isDirect: false, isMine: false, isAdmin: false, expectedForMe: true, expectedForEveryone: false),
        ]

        for row in rows {
            let capability = MessageDeletePolicy.capability(
                isDirectMessage: row.isDirect,
                isMine: row.isMine,
                isSelfAdmin: row.isAdmin,
                localDeleteSupported: true,
                remoteDeleteSupported: true,
                isDeleted: false,
                isHidden: false
            )
            #expect(capability.canDeleteForMe == row.expectedForMe, "\(row.name): local scope")
            #expect(capability.canDeleteForEveryone == row.expectedForEveryone, "\(row.name): remote scope")
            #expect(capability.canDelete == (row.expectedForMe || row.expectedForEveryone))
        }
    }

    @Test func capabilityRejectsUnavailableOrAlreadyRemovedMessages() {
        let base = MessageDeletePolicy.capability(
            isDirectMessage: false,
            isMine: true,
            isSelfAdmin: false,
            localDeleteSupported: false,
            remoteDeleteSupported: false,
            isDeleted: false,
            isHidden: false
        )
        let deleted = MessageDeletePolicy.capability(
            isDirectMessage: false,
            isMine: true,
            isSelfAdmin: true,
            localDeleteSupported: true,
            remoteDeleteSupported: true,
            isDeleted: true,
            isHidden: false
        )
        let hidden = MessageDeletePolicy.capability(
            isDirectMessage: false,
            isMine: true,
            isSelfAdmin: true,
            localDeleteSupported: true,
            remoteDeleteSupported: true,
            isDeleted: false,
            isHidden: true
        )

        #expect(base == .unavailable)
        #expect(deleted == .unavailable)
        #expect(hidden == .unavailable)
    }

    @Test func presentationChoosesScopeLocalAndModerationCopy() {
        let both = MessageDeleteCapability(canDeleteForMe: true, canDeleteForEveryone: true)
        let local = MessageDeleteCapability(canDeleteForMe: true, canDeleteForEveryone: false)

        #expect(MessageDeletePresentation.supportingCopy(capability: both, isMine: true) == .chooseScope)
        #expect(MessageDeletePresentation.supportingCopy(capability: local, isMine: false) == .localOnly)
        #expect(MessageDeletePresentation.supportingCopy(capability: both, isMine: false) == .moderation)
    }

    @Test func tombstoneKeepsTimestampButDropsDeliveryStatus() {
        #expect(!MessageTombstonePresentation.showsDeliveryStatus(isDeleted: true))
        #expect(MessageTombstonePresentation.showsDeliveryStatus(isDeleted: false))
    }

    @Test func viewModelCapabilityIsAvailableForIngestedMessages() throws {
        // Positive regression coverage for delete availability through the
        // full view-model wiring: an ingested message must surface delete
        // scopes. The pure-policy positives alone let a wiring break hide.
        let accountRef = "delete-available-\(UUID().uuidString)"
        let me = hex("11")
        let other = hex("22")
        // Engine-shaped 16-byte group id (the real engine's MLS group id
        // length, verified against a live-created group). Fixtures previously
        // used 64-char ids by construction, which let a 32-byte length gate
        // on group ids pass every test while making every REAL conversation's
        // delete capability unavailable. This deterministic fixture is the
        // permanent guard — it needs no account transport.
        let group = groupRecord(id: String(repeating: "ab", count: 16), name: "Availability", admins: [me])
        let appState = try appState(accountRef: accountRef, accountIdHex: me)
        let viewModel = ConversationViewModel(appState: appState, group: group)

        let mine = appRecord(id: hex("44"), groupId: group.groupIdHex, sender: me, direction: "sent")
        let theirs = appRecord(id: hex("55"), groupId: group.groupIdHex, sender: other, direction: "received")
        let page = TimelinePageFfi(
            messages: [
                timelineRecord(id: mine.messageIdHex, groupId: group.groupIdHex, sender: me, at: 1),
                timelineRecord(id: theirs.messageIdHex, groupId: group.groupIdHex, sender: other, at: 2),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )
        viewModel.applyTimelinePage(page, placement: .window)

        // Own message in a named group: both scopes.
        let mineCapability = viewModel.deleteCapability(for: mine)
        #expect(mineCapability.canDeleteForMe)
        #expect(mineCapability.canDeleteForEveryone)

        // Another member's message, while self is admin: moderation scope.
        let theirsCapability = viewModel.deleteCapability(for: theirs)
        #expect(theirsCapability.canDeleteForMe)
        #expect(theirsCapability.canDeleteForEveryone)
        #expect(viewModel.canModerateReports)
        #expect(viewModel.canReport(theirs))
        appState.activeAccountRef = "replacement-account"
        #expect(!viewModel.canModerateReports)
        #expect(!viewModel.canReport(theirs))
    }

    @Test func moderationRefreshSurvivesNavigationAwayFromTheVisibleTimeline() throws {
        let state = try appState(accountRef: "reports", accountIdHex: hex("11"))
        state.setPhase(.ready)
        #expect(state.visibleChat == nil)
        state.moderationProjectionRoute = AppState.GroupRecoveryUpdate(accountID: hex("11"), groupID: "group")
        let generation = try #require(state.runtimeEventsGeneration)
        let update = RuntimeProjectionUpdateFfi(accountIdHex: hex("11"), accountLabel: "reports",
            update: TimelineProjectionUpdateFfi(groupIdHex: "group", messages: [], changes: [],
                chatListRow: nil, chatListTrigger: .snapshotRefresh))
        state.handleRuntimeEvent(.projectionUpdated(update: update), generation: generation)
        #expect(state.groupProjectionUpdate?.groupID == "group")
        let token = state.groupProjectionUpdate?.id
        var unrelated = update
        unrelated.update.groupIdHex = "other-group"
        state.handleRuntimeEvent(.projectionUpdated(update: unrelated), generation: generation)
        #expect(state.groupProjectionUpdate?.id == token)
        state.handleRuntimeEvent(.projectionUpdated(update: update), generation: generation - 1)
        #expect(state.groupProjectionUpdate?.id == token)
    }

    @Test func reportingDoesNotRequireAdminOrMessageOwnership() throws {
        let me = hex("11")
        let other = hex("22")
        let group = groupRecord(id: String(repeating: "ab", count: 16), name: "Reports", admins: [other])
        let state = try appState(accountRef: "reports-\(UUID())", accountIdHex: me)
        let model = ConversationViewModel(appState: state, group: group)
        let mine = appRecord(id: hex("44"), groupId: group.groupIdHex, sender: me, direction: "sent")
        let theirs = appRecord(id: hex("55"), groupId: group.groupIdHex, sender: other, direction: "received")
        model.applyTimelinePage(TimelinePageFfi(messages: [
            timelineRecord(id: mine.messageIdHex, groupId: group.groupIdHex, sender: me, at: 1),
            timelineRecord(id: theirs.messageIdHex, groupId: group.groupIdHex, sender: other, at: 2)
        ], hasMoreBefore: false, hasMoreAfter: false), placement: .window)
        #expect(model.canReport(mine))
        #expect(model.canReport(theirs))
        #expect(!model.canModerateReports)
        #expect(!model.deleteCapability(for: theirs).canDeleteForEveryone)
        #expect(!model.canReport(appRecord(id: "", groupId: group.groupIdHex, sender: me, direction: "sent")))
    }

    @Test func moderationPanelSeparatesDismissalFromDeletionAndHonorsPending() async throws {
        let me = hex("11")
        let group = groupRecord(id: String(repeating: "ab", count: 16), name: "Moderation", admins: [me])
        let state = try appState(accountRef: "moderation-\(UUID())", accountIdHex: me)
        let conversation = ConversationViewModel(appState: state, group: group)
        let message = timelineRecord(id: hex("55"), groupId: group.groupIdHex, at: 1)
        let client = ModerationFixture(message: message)
        let model = GroupModerationModel(client: client)
        await model.load(conversation: conversation, appState: state)
        #expect(model.entries.count == 2)
        let first = try #require(model.entries.first)
        await model.act(on: first, deleting: false, conversation: conversation, appState: state)
        #expect(await client.dismissCalls == 1)
        #expect(await client.deleteCalls == 0)
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.message?.plaintext == message.plaintext)
        let second = try #require(model.entries.first)
        await client.setPending()
        await model.act(on: second, deleting: true, conversation: conversation, appState: state)
        #expect(model.pendingActions[second.id] == true)
        #expect(model.entries.first?.message?.deleted == false)
        await model.act(on: second, deleting: true, conversation: conversation, appState: state)
        #expect(await client.deleteCalls == 1)
        await client.finishDeletion()
        await model.load(conversation: conversation, appState: state)
        #expect(model.pendingActions.isEmpty)
        #expect(model.entries.first?.message?.deleted == true)
        #expect(model.entries.first?.message?.plaintext == "")
    }

    @Test func moderationPanelRejectsNonAdminsAndKeepsFailedActionsReviewable() async throws {
        let me = hex("11")
        var group = groupRecord(id: String(repeating: "ab", count: 16), name: "Moderation", admins: [])
        let state = try appState(accountRef: "moderation-\(UUID())", accountIdHex: me)
        let client = ModerationFixture(message: timelineRecord(id: hex("55"), groupId: group.groupIdHex, at: 1))
        let model = GroupModerationModel(client: client)
        await model.load(conversation: ConversationViewModel(appState: state, group: group), appState: state)
        #expect(await client.readCalls == 0)
        group.admins = [me]
        let conversation = ConversationViewModel(appState: state, group: group)
        await model.load(conversation: conversation, appState: state)
        let entry = try #require(model.entries.first)
        await client.setFailing()
        await model.act(on: entry, deleting: false, conversation: conversation, appState: state)
        #expect(model.error != nil)
        #expect(model.entries.count == 2)
        #expect(model.pendingActions.isEmpty)
    }

    @Test func viewModelCapabilityRejectsMissingAccountAndMalformedMessageIds() async throws {
        let accountRef = "delete-capability-\(UUID().uuidString)"
        let me = hex("11")
        let group = groupRecord(id: hex("aa"), name: "Capability test")
        let appState = try appState(accountRef: accountRef, accountIdHex: me)
        defer { appState.activeAccountRef = accountRef }
        let viewModel = ConversationViewModel(appState: appState, group: group)
        let valid = appRecord(id: hex("44"), groupId: group.groupIdHex, sender: me, direction: "sent")
        let malformed = appRecord(id: "not-hex", groupId: group.groupIdHex, sender: me, direction: "sent")

        #expect(viewModel.deleteCapability(for: malformed) == .unavailable)
        #expect(viewModel.deleteCapability(for: valid) == .unavailable)
        appState.activeAccountRef = nil
        #expect(viewModel.deleteCapability(for: valid) == .unavailable)
        #expect(!(await viewModel.deleteMessageForMe(valid)))
    }

    @Test func hideStoreAcceptsEngineShapedGroupIds() {
        // The for-me path persists through MessageHideStore; a 16-byte group
        // id must produce a valid conversation key.
        let key = MessageHideStore.conversationKey(
            accountRef: "account-a",
            groupIdHex: String(repeating: "AB", count: 16)
        )
        #expect(key != nil)
        #expect(key?.hasSuffix(String(repeating: "ab", count: 16)) == true)
    }

    @Test func localHideIsScopedIdempotentAndClearedPerAccount() throws {
        let suiteName = "MessageDeletionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageId = hex("11")

        let first = MessageHideStore.hideMessage(
            accountRef: "account:a",
            groupIdHex: hex("aa"),
            messageIdHex: messageId.uppercased(),
            defaults: defaults
        )
        let second = MessageHideStore.hideMessage(
            accountRef: "account:a",
            groupIdHex: hex("aa"),
            messageIdHex: messageId,
            defaults: defaults
        )
        MessageHideStore.hideMessage(
            accountRef: "account:b",
            groupIdHex: hex("aa"),
            messageIdHex: hex("22"),
            defaults: defaults
        )

        #expect(first == [messageId])
        #expect(second == [messageId])
        #expect(MessageHideStore.hiddenMessageIds(
            accountRef: "account:a",
            groupIdHex: hex("bb"),
            defaults: defaults
        ).isEmpty)
        #expect(MessageHideStore.conversationKey(accountRef: "ab:c", groupIdHex: hex("aa"))
                != MessageHideStore.conversationKey(accountRef: "ab", groupIdHex: hex("aa")))
        #expect(MessageHideStore.conversationKey(accountRef: "account:a", groupIdHex: "not-hex") == nil)
        #expect(MessageHideStore.hideMessage(
            accountRef: "account:a",
            groupIdHex: hex("aa"),
            messageIdHex: "not-hex",
            defaults: defaults
        ).isEmpty)

        MessageHideStore.clearAll(accountRef: "account:a", defaults: defaults)

        #expect(MessageHideStore.hiddenMessageIds(
            accountRef: "account:a",
            groupIdHex: hex("aa"),
            defaults: defaults
        ).isEmpty)
        #expect(MessageHideStore.hiddenMessageIds(
            accountRef: "account:b",
            groupIdHex: hex("aa"),
            defaults: defaults
        ) == [hex("22")])
    }

    @Test func concurrentLocalHidesDoNotLoseUpdates() async throws {
        let suiteName = "MessageDeletionConcurrencyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountRef = "account:concurrent"
        let groupId = hex("aa")
        let messageIds = (1...32).map { String(format: "%064x", $0) }

        await withTaskGroup(of: Void.self) { tasks in
            for messageId in messageIds {
                tasks.addTask {
                    _ = MessageHideStore.hideMessage(
                        accountRef: accountRef,
                        groupIdHex: groupId,
                        messageIdHex: messageId,
                        defaults: defaults
                    )
                }
            }
        }

        #expect(MessageHideStore.hiddenMessageIds(
            accountRef: accountRef,
            groupIdHex: groupId,
            defaults: defaults
        ) == Set(messageIds))
    }

    @Test func timelineFiltersPersistedHiddenRowsWithoutDroppingProjectionRecords() throws {
        let hiddenId = hex("11")
        let visibleId = hex("22")
        let replyId = hex("33")
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"), hiddenMessageIds: [hiddenId])
        let page = TimelinePageFfi(
            messages: [
                timelineRecord(id: hiddenId, at: 1),
                timelineRecord(id: visibleId, at: 2),
                timelineRecord(id: replyId, at: 3, replyToMessageIdHex: hiddenId),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        store.applyTimelinePage(page, placement: .window)

        #expect(renderedMessageIds(in: store) == [visibleId, replyId])
        #expect(store.record(for: hiddenId) != nil)
        #expect(store.replyPreview(for: try #require(store.record(for: replyId))) != nil)

        store.setHiddenMessageIds([hiddenId, visibleId])
        #expect(renderedMessageIds(in: store) == [replyId])

        store.setHiddenMessageIds([hiddenId])
        #expect(renderedMessageIds(in: store) == [visibleId, replyId])
    }

    @Test func loadedReplyTargetFallbackDoesNotResurfaceDeletedPlaintext() throws {
        let parentId = hex("71")
        let replyId = hex("72")
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        let parent = timelineRecord(id: parentId, at: 1, deleted: true)
        let reply = timelineRecord(
            id: replyId,
            at: 2,
            replyToMessageIdHex: parentId,
            includeReplyPreview: false
        )

        store.applyTimelinePage(
            TimelinePageFfi(messages: [parent, reply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let replyRecord = try #require(store.record(for: replyId))
        #expect(store.replyPreview(for: replyRecord)?.text == "This message was deleted")
    }

    @Test func deleteForMePublishesNothingAndSurvivesViewModelRecreation() async throws {
        let accountRef = "delete-local-\(UUID().uuidString)"
        let me = hex("11")
        let group = groupRecord(id: hex("aa"), name: "Local delete test")
        let appState = try appState(accountRef: accountRef, accountIdHex: me)
        var remoteDeleteCalls = 0
        let operation: ConversationViewModel.DeleteMessageOperation = { _, _, _, _ in
            remoteDeleteCalls += 1
            return SendSummaryFfi(published: 1, messageIds: [])
        }
        let message = appRecord(id: hex("44"), groupId: group.groupIdHex, sender: hex("22"), direction: "received")
        let page = TimelinePageFfi(
            messages: [timelineRecord(id: message.messageIdHex, groupId: group.groupIdHex, sender: message.sender, at: 1)],
            hasMoreBefore: false,
            hasMoreAfter: false
        )
        defer { MessageHideStore.clearAll(accountRef: accountRef) }

        let first = ConversationViewModel(
            appState: appState,
            group: group,
            deleteMessageOperation: operation
        )
        first.applyTimelinePage(page, placement: .window)
        #expect(await first.deleteMessageForMe(message))
        #expect(first.timeline.isEmpty)
        #expect(remoteDeleteCalls == 0)

        let recreated = ConversationViewModel(
            appState: appState,
            group: group,
            deleteMessageOperation: operation
        )
        recreated.applyTimelinePage(page, placement: .window)
        #expect(recreated.timeline.isEmpty)
        #expect(remoteDeleteCalls == 0)
    }

    @Test func directMessageAdminCannotDeleteAnotherSendersMessageForEveryone() async throws {
        let accountRef = "delete-dm-\(UUID().uuidString)"
        let me = hex("11")
        let group = groupRecord(id: hex("aa"), name: "", admins: [me])
        let appState = try appState(accountRef: accountRef, accountIdHex: me)
        var remoteDeleteCalls = 0
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group,
            initialMemberCount: 2,
            deleteMessageOperation: { _, _, _, _ in
                remoteDeleteCalls += 1
                return SendSummaryFfi(published: 1, messageIds: [])
            }
        )
        let message = appRecord(id: hex("55"), groupId: group.groupIdHex, sender: hex("22"), direction: "received")
        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [timelineRecord(
                    id: message.messageIdHex,
                    groupId: group.groupIdHex,
                    sender: message.sender,
                    at: 1
                )],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        #expect(viewModel.deleteCapability(for: message).canDeleteForMe)
        #expect(!viewModel.deleteCapability(for: message).canDeleteForEveryone)
        let deleted = await viewModel.deleteMessageForEveryone(message)
        #expect(!deleted)
        #expect(remoteDeleteCalls == 0)
    }

    @Test func canonicalTimelineRecordPreventsSpoofedSenderAuthorization() async throws {
        let accountRef = "delete-spoof-\(UUID().uuidString)"
        let me = hex("11")
        let other = hex("22")
        let messageId = hex("56")
        let group = groupRecord(id: hex("aa"), name: "Authorization test")
        let appState = try appState(accountRef: accountRef, accountIdHex: me)
        var remoteDeleteCalls = 0
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group,
            deleteMessageOperation: { _, _, _, _ in
                remoteDeleteCalls += 1
                return SendSummaryFfi(published: 1, messageIds: [])
            }
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [timelineRecord(
                    id: messageId,
                    groupId: group.groupIdHex,
                    sender: other,
                    at: 1
                )],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )
        let spoofed = appRecord(id: messageId, groupId: group.groupIdHex, sender: me, direction: "sent")

        let capability = viewModel.deleteCapability(for: spoofed)
        #expect(capability.canDeleteForMe)
        #expect(!capability.canDeleteForEveryone)
        let deleted = await viewModel.deleteMessageForEveryone(spoofed)
        #expect(!deleted)
        #expect(remoteDeleteCalls == 0)
    }

    @Test func failedRemoteDeleteRollsBackAndCanBeRetried() async throws {
        let accountRef = "delete-failure-\(UUID().uuidString)"
        let me = hex("11")
        let group = groupRecord(id: hex("aa"), name: "Failure test")
        let appState = try appState(accountRef: accountRef, accountIdHex: me)
        var remoteDeleteCalls = 0
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group,
            deleteMessageOperation: { _, _, _, _ in
                remoteDeleteCalls += 1
                throw DeleteTestError.failed
            }
        )
        let message = appRecord(id: hex("66"), groupId: group.groupIdHex, sender: me, direction: "sent")
        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [timelineRecord(id: message.messageIdHex, groupId: group.groupIdHex, sender: me, at: 1)],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        let deleted = await viewModel.deleteMessageForEveryone(message)
        #expect(!deleted)
        #expect(remoteDeleteCalls == 1)
        #expect(!viewModel.isDeleted(message.messageIdHex))
        #expect(viewModel.timeline.count == 1)
        #expect(viewModel.deleteCapability(for: message).canDeleteForEveryone)
    }

    @Test func repeatedRemoteDeleteStartsOnlyOneMutation() async throws {
        let accountRef = "delete-repeat-\(UUID().uuidString)"
        let me = hex("11")
        let group = groupRecord(id: hex("aa"), name: "Repeat test")
        let appState = try appState(accountRef: accountRef, accountIdHex: me)
        let barrier = DeleteOperationBarrier()
        var remoteDeleteCalls = 0
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group,
            deleteMessageOperation: { _, _, _, _ in
                remoteDeleteCalls += 1
                if remoteDeleteCalls == 1 {
                    await barrier.arriveAndWait()
                }
                return SendSummaryFfi(published: 1, messageIds: [])
            }
        )
        let message = appRecord(id: hex("77"), groupId: group.groupIdHex, sender: me, direction: "sent")
        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [timelineRecord(
                    id: message.messageIdHex,
                    groupId: group.groupIdHex,
                    sender: me,
                    at: 1
                )],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        let first = Task { await viewModel.deleteMessageForEveryone(message) }
        await barrier.waitUntilStarted()
        let repeated = await viewModel.deleteMessageForEveryone(message)
        await barrier.release()
        let firstResult = await first.value

        #expect(firstResult)
        #expect(!repeated)
        #expect(remoteDeleteCalls == 1)
        #expect(viewModel.isDeleted(message.messageIdHex))
    }

    private func appState(accountRef: String, accountIdHex: String) throws -> AppState {
        let state = AppState(client: try MarmotClient.testClient())
        state.accountStore.accounts = [
            AccountSummaryFfi(
                label: accountRef,
                accountIdHex: accountIdHex,
                localSigning: true,
                signedOut: false,
                running: true
            ),
        ]
        state.activeAccountRef = accountRef
        return state
    }

    private func groupRecord(
        id: String,
        name: String,
        admins: [String] = []
    ) -> AppGroupRecordFfi {
        AppGroupRecordFfi(
            groupIdHex: id,
            endpoint: "",
            name: name,
            description: "",
            admins: admins,
            relays: [],
            nostrGroupIdHex: "",
            avatarUrl: nil,
            avatarDim: nil,
            avatarThumbhash: nil,
            encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                componentId: 0,
                component: "",
                required: false,
                mediaFormat: "",
                allowedLocatorKinds: [],
                defaultBlobEndpoints: []
            ),
            archived: false,
            pendingConfirmation: false,
            selfMembership: .member,
            welcomerAccountIdHex: nil,
            viaWelcomeMessageIdHex: nil
        )
    }

    private func appRecord(
        id: String,
        groupId: String,
        sender: String,
        direction: String
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: id,
            direction: direction,
            groupIdHex: groupId,
            sender: sender,
            plaintext: "message",
            contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 1,
            receivedAt: 1
        )
    }

    private func timelineRecord(
        id: String,
        groupId: String = String(repeating: "aa", count: 32),
        sender: String = String(repeating: "22", count: 32),
        at: UInt64,
        replyToMessageIdHex: String? = nil,
        includeReplyPreview: Bool = true,
        deleted: Bool = false
    ) -> TimelineMessageRecordFfi {
        TimelineMessageRecordFfi(
            messageIdHex: id,
            sourceMessageIdHex: id,
            direction: "received",
            groupIdHex: groupId,
            sender: sender,
            plaintext: "message \(at)",
            contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: replyToMessageIdHex.map {
                [MessageTagFfi(values: [MessageSemantics.eventRefTag, $0])]
            } ?? [],
            timelineAt: at,
            receivedAt: at,
            replyToMessageIdHex: replyToMessageIdHex,
            replyPreview: includeReplyPreview ? replyToMessageIdHex.map {
                TimelineReplyPreviewFfi(
                    messageIdHex: $0,
                    sender: hex("22"),
                    plaintext: "hidden target",
                    kind: MessageSemantics.kindChat,
                    mediaJson: nil,
                    media: [],
                    agentTextStreamJson: nil,
                    deleted: false
                )
            } : nil,
            mediaJson: nil,
            media: [],
            agentTextStreamJson: nil,
            groupSystem: nil,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
            edit: nil,
            deleted: deleted,
            deletedByMessageIdHex: nil,
            invalidationStatus: nil
        )
    }

    private func renderedMessageIds(in store: TimelineStore) -> [String] {
        store.timeline.compactMap { item in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
    }

    private func hex(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }
}

private enum DeleteTestError: Error {
    case failed
}

private actor DeleteOperationBarrier {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor ModerationFixture: GroupModerationClient {
    var message: TimelineMessageRecordFfi
    var dismissed = Set<String>()
    var pending = false
    var failing = false
    private(set) var dismissCalls = 0
    private(set) var deleteCalls = 0
    private(set) var readCalls = 0

    init(message: TimelineMessageRecordFfi) { self.message = message }
    func setPending() { pending = true }
    func setFailing() { failing = true }
    func finishDeletion() {
        message.deleted = true
        message.plaintext = ""
        pending = false
    }
    func contentReports(accountRef: String, groupID: String, after: String?) async throws -> ContentReportPageFfi {
        readCalls += 1
        return ContentReportPageFfi(reports: ["one", "two"].map {
            ContentReportFfi(reportIdHex: $0, messageIdHex: message.messageIdHex,
                messageAuthor: message.sender, reporter: message.sender, reason: .spam,
                explanation: "", reportedAt: 1, dismissed: dismissed.contains($0))
        }, nextCursor: nil)
    }
    func reportedMessage(accountRef: String, groupID: String, messageID: String) async throws -> TimelineMessageRecordFfi? { message }
    func dismissReport(accountRef: String, groupID: String, reportID: String) async throws -> SendSummaryFfi {
        dismissCalls += 1
        if failing { throw URLError(.notConnectedToInternet) }
        if !pending { dismissed.insert(reportID) }
        return summary()
    }
    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        deleteCalls += 1
        if failing { throw URLError(.notConnectedToInternet) }
        if !pending { finishDeletion() }
        return summary()
    }
    private func summary() -> SendSummaryFfi {
        SendSummaryFfi(published: pending ? 0 : 1, messageIds: ["operation"],
            acceptDisposition: pending ? .acceptedPending : .published, maintenanceDisposition: .ready)
    }
}
