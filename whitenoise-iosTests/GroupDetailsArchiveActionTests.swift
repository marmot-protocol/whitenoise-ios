import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct GroupDetailsArchiveActionTests {

    /// #446 — the Archive/Unarchive row already disables itself from
    /// `membershipActionInFlight`; `setArchived` must take that gate before the
    /// awaited publish so a fast double-tap cannot start a second archive publish.
    @Test func setArchivedRejectsConcurrentPublishUntilFirstCompletes() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        let model = GroupDetailsViewModel()
        let publisher = GroupArchivePublishProbe()
        var changedRecords: [AppGroupRecordFfi] = []

        model.conversation = conversation
        model.onGroupChanged = { changedRecords.append($0) }
        model.setGroupArchivedForTesting = { accountRef, groupIdHex, archived in
            try await publisher.publish(accountRef: accountRef, groupIdHex: groupIdHex, archived: archived)
        }

        let first = Task { @MainActor in
            await model.setArchived(true, using: appState)
        }
        await publisher.waitUntilStarted()

        #expect(model.membershipActionInFlight)

        let second = Task { @MainActor in
            await model.setArchived(true, using: appState)
        }
        await second.value

        #expect(publisher.requests == [
            GroupArchivePublishProbe.Request(
                accountRef: "account-1",
                groupIdHex: groupIdHex,
                archived: true
            ),
        ])
        #expect(changedRecords.isEmpty)

        publisher.completeFirst(with: archiveTestGroup(groupIdHex: groupIdHex, archived: true))
        await first.value

        #expect(!model.membershipActionInFlight)
        #expect(conversation.group.archived)
        #expect(changedRecords.map(\.archived) == [true])
    }

    @Test func profileUpdateRejectsConcurrentPublishUntilFirstCompletes() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        let model = GroupDetailsViewModel()
        let publisher = GroupProfilePublishProbe()

        model.conversation = conversation
        model.renameDraft = "Renamed group"
        model.descriptionDraft = "A shared description"
        model.updateGroupProfileForTesting = { accountRef, groupIdHex, name, description in
            try await publisher.publish(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                name: name,
                description: description
            )
        }

        let first = Task { @MainActor in
            await model.updateProfile(using: appState)
        }
        await publisher.waitUntilStarted()

        #expect(model.membershipActionInFlight)

        let second = Task { @MainActor in
            await model.updateProfile(using: appState)
        }
        await second.value

        #expect(publisher.requests == [
            GroupProfilePublishProbe.Request(
                accountRef: "account-1",
                groupIdHex: groupIdHex,
                name: "Renamed group",
                description: "A shared description"
            ),
        ])

        publisher.completeFirst()
        await first.value

        #expect(!model.membershipActionInFlight)
    }

    @Test func updateGroupImageRejectsConcurrentPublishUntilFirstCompletes() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        let model = GroupDetailsViewModel()
        let publisher = GroupAvatarPublishProbe()
        var progressPhases: [GroupImageProgressPhase?] = []
        let draft = GroupImageUploadDraft(
            data: Data([1, 2, 3]),
            mediaType: "image/jpeg",
            sourceURL: nil,
            dim: nil,
            thumbhash: nil
        )

        model.conversation = conversation
        model.updateGroupImageForTesting = { accountRef, groupIdHex, data, mediaType in
            try await publisher.publish(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                data: data,
                mediaType: mediaType
            )
        }

        let first = Task { @MainActor in
            try await model.updateGroupImage(
                draft: draft,
                using: appState,
                onProgress: { progressPhases.append($0) }
            )
        }
        await publisher.waitUntilStarted()

        #expect(model.membershipActionInFlight)
        #expect(progressPhases == [.updating])
        #expect(appState.activeToast == nil)

        let second = Task { @MainActor in
            try await model.updateGroupImage(draft: draft, using: appState)
        }
        await #expect(throws: GroupDetailsActionError.operationInFlight) {
            try await second.value
        }

        #expect(publisher.requests == [
            GroupAvatarPublishProbe.Request(
                accountRef: "account-1",
                groupIdHex: groupIdHex,
                data: draft.data,
                mediaType: draft.mediaType
            ),
        ])

        publisher.completeFirst()
        try await first.value

        #expect(!model.membershipActionInFlight)
        #expect(progressPhases == [.updating, .finishing, nil])
    }

    @Test func encryptedImageUploadClearsLegacyURLOnlyAfterUploadSucceeds() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(
                groupIdHex: groupIdHex,
                archived: false,
                avatarUrl: "https://legacy.example/group.jpg"
            )
        )
        let model = GroupDetailsViewModel()
        let draft = GroupImageUploadDraft(
            data: Data([7, 8, 9]),
            mediaType: "image/jpeg",
            sourceURL: nil,
            dim: nil,
            thumbhash: nil
        )
        var operations: [String] = []
        model.conversation = conversation
        model.updateGroupImageForTesting = { _, _, _, _ in
            operations.append("upload")
            return SendSummaryFfi(published: 1, messageIds: ["upload"])
        }
        model.updateGroupAvatarUrlForTesting = { _, _, url in
            #expect(url == nil)
            operations.append("clear-url")
            return SendSummaryFfi(published: 1, messageIds: ["clear"])
        }

        try await model.updateGroupImage(draft: draft, using: appState)

        #expect(operations == ["upload", "clear-url"])
    }

    @Test func legacyURLClearRetryDoesNotUploadEncryptedImageAgain() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(
                groupIdHex: groupIdHex,
                archived: false,
                avatarUrl: "https://legacy.example/group.jpg"
            )
        )
        let model = GroupDetailsViewModel()
        let draft = GroupImageUploadDraft(
            data: Data([1]),
            mediaType: "image/jpeg",
            sourceURL: nil,
            dim: nil,
            thumbhash: nil
        )
        var uploadCount = 0
        var clearCount = 0
        model.conversation = conversation
        model.updateGroupImageForTesting = { _, _, _, _ in
            uploadCount += 1
            return SendSummaryFfi(published: 1, messageIds: ["upload"])
        }
        model.updateGroupAvatarUrlForTesting = { _, _, _ in
            clearCount += 1
            if clearCount == 1 {
                throw GroupImageTestError.clearFailed
            }
            return SendSummaryFfi(published: 1, messageIds: ["clear"])
        }

        await #expect(throws: GroupImageTestError.self) {
            try await model.updateGroupImage(draft: draft, using: appState)
        }
        try await model.updateGroupImage(draft: draft, using: appState)

        #expect(uploadCount == 1)
        #expect(clearCount == 2)
    }

    @Test func clearingDescriptionPublishesTheExplicitEmptyStringSentinel() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(
                groupIdHex: groupIdHex,
                archived: false,
                description: "Existing description"
            )
        )
        let model = GroupDetailsViewModel()
        var requests: [(accountRef: String, groupIdHex: String, description: String)] = []

        model.conversation = conversation
        model.renameDraft = conversation.group.name
        model.descriptionDraft = " \n\t "
        model.updateGroupProfileForTesting = { accountRef, groupIdHex, _, description in
            requests.append((accountRef, groupIdHex, description))
            return SendSummaryFfi(published: 1, messageIds: ["description-update"])
        }

        let succeeded = await model.updateProfile(using: appState)

        #expect(succeeded)
        #expect(requests.count == 1)
        #expect(requests.first?.accountRef == "account-1")
        #expect(requests.first?.groupIdHex == groupIdHex)
        #expect(requests.first?.description == "")
        #expect(!model.membershipActionInFlight)
    }

    @Test func sharedMediaProjectionLoadsOnceUnlessExplicitlyRefreshed() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        let model = GroupDetailsViewModel()
        var requestCount = 0

        model.conversation = conversation
        model.listMediaForTesting = { _, _ in
            requestCount += 1
            return []
        }

        await model.loadSharedMedia(using: appState)
        await model.loadSharedMedia(using: appState)
        #expect(requestCount == 1)

        await model.loadSharedMedia(using: appState, force: true)
        #expect(requestCount == 2)
    }

    @Test func leaveMarksConversationInactiveAndNotifiesParent() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        let model = GroupDetailsViewModel()
        var changedRecords: [AppGroupRecordFfi] = []
        var leftGroupIds: [String] = []
        var dismissed = false
        var leaveRequests: [(String, String)] = []

        model.conversation = conversation
        model.onGroupChanged = { changedRecords.append($0) }
        model.onGroupLeft = { leftGroupIds.append($0) }
        model.leaveGroupForTesting = { accountRef, groupIdHex in
            leaveRequests.append((accountRef, groupIdHex))
            return SendSummaryFfi(published: 1, messageIds: ["leave-message"])
        }

        await model.leave(using: appState, dismiss: { dismissed = true })

        #expect(leaveRequests.count == 1)
        #expect(leaveRequests.first?.0 == "account-1")
        #expect(leaveRequests.first?.1 == groupIdHex)
        #expect(conversation.group.selfMembership == .left)
        #expect(conversation.group.leaveRequestPending)
        #expect(changedRecords.map(\.selfMembership) == [.left])
        #expect(changedRecords.map(\.leaveRequestPending) == [true])
        #expect(leftGroupIds == [groupIdHex])
        #expect(dismissed)
    }

    @Test func endGroupRecordsDurableIntentAndDisablesMessagingImmediately() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        conversation.setManagementStateForTesting(disbandManagementState(
            disbandingEnabled: true,
            canDisband: true
        ))
        let model = GroupDetailsViewModel()
        var disbandRequests: [(String, String)] = []
        var changedRecords: [AppGroupRecordFfi] = []

        model.conversation = conversation
        model.onGroupChanged = { changedRecords.append($0) }
        model.disbandGroupForTesting = { accountRef, groupIdHex in
            disbandRequests.append((accountRef, groupIdHex))
            return .pending(requestedAtMs: 1_000)
        }

        await model.endGroup(using: appState)

        #expect(disbandRequests.count == 1)
        #expect(disbandRequests.first?.0 == "account-1")
        #expect(disbandRequests.first?.1 == groupIdHex)
        #expect(conversation.group.disbanding)
        #expect(conversation.group.disbandRequest == .pending(requestedAtMs: 1_000))
        #expect(!conversation.canSendMessages)
        #expect(
            conversation.inactiveGroupMessage
                == GroupManagementPresentation.disbandingComposerMessage
        )
        #expect(changedRecords.map(\.disbanding) == [true])
    }

    @Test func endGroupEnablesLifecycleAndDisbandsFromOneConfirmation() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let group = archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        let conversation = ConversationViewModel(appState: appState, group: group)
        conversation.setManagementStateForTesting(disbandManagementState(
            canEnableDisbanding: true
        ))
        let model = GroupDetailsViewModel()
        var enableCount = 0
        var disbandCount = 0

        model.conversation = conversation
        model.enableGroupDisbandingForTesting = { _, _ in
            enableCount += 1
            return GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 1, messageIds: ["enable"]),
                details: GroupDetailsFfi(group: group, members: []),
                managementState: disbandManagementState(
                    disbandingEnabled: true,
                    canDisband: true
                )
            )
        }
        model.disbandGroupForTesting = { _, _ in
            disbandCount += 1
            return .pending(requestedAtMs: 2_000)
        }

        await model.endGroup(using: appState)

        #expect(enableCount == 1)
        #expect(disbandCount == 1)
        #expect(conversation.group.disbanding)
        #expect(conversation.group.disbandRequest == .pending(requestedAtMs: 2_000))
    }

    @Test func alreadyRequestedLeaveIsPresentedAsDurableProgress() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        let model = GroupDetailsViewModel()
        var changedRecords: [AppGroupRecordFfi] = []
        var leftGroupIds: [String] = []
        var dismissed = false

        model.conversation = conversation
        model.onGroupChanged = { changedRecords.append($0) }
        model.onGroupLeft = { leftGroupIds.append($0) }
        model.leaveGroupForTesting = { _, _ in
            throw MarmotKitError.LeaveAlreadyRequested(groupIdHex: groupIdHex)
        }

        await model.leave(using: appState, dismiss: { dismissed = true })

        #expect(conversation.group.selfMembership == .member)
        #expect(conversation.group.leaveRequestPending)
        #expect(changedRecords.map(\.leaveRequestPending) == [true])
        #expect(leftGroupIds == [groupIdHex])
        #expect(dismissed)
    }

    @Test func deleteLocalIsGatedUntilMembershipIsInactive() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false)
        )
        let model = GroupDetailsViewModel()
        var deleteRequests: [(String, String)] = []

        model.conversation = conversation
        model.deleteGroupLocalForTesting = { accountRef, groupIdHex in
            deleteRequests.append((accountRef, groupIdHex))
            return true
        }

        await model.deleteLocal(using: appState, dismiss: {})

        #expect(deleteRequests.isEmpty)
        #expect(model.actionError == L10n.string("Leave this group before deleting the local copy."))
    }

    @Test func deleteLocalRemovesInactiveGroupFromParent() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(groupIdHex: groupIdHex, archived: false, selfMembership: .left)
        )
        let model = GroupDetailsViewModel()
        var deleteRequests: [(String, String)] = []
        var deletedGroupIds: [String] = []
        var dismissed = false

        model.conversation = conversation
        model.onGroupDeleted = { deletedGroupIds.append($0) }
        model.deleteGroupLocalForTesting = { accountRef, groupIdHex in
            deleteRequests.append((accountRef, groupIdHex))
            return true
        }

        await model.deleteLocal(using: appState, dismiss: { dismissed = true })

        #expect(deleteRequests.count == 1)
        #expect(deleteRequests.first?.0 == "account-1")
        #expect(deleteRequests.first?.1 == groupIdHex)
        #expect(deletedGroupIds == [groupIdHex])
        #expect(dismissed)
    }

    @Test func deleteLocalIsUnavailableWhileStillAMemberWithALeaveInFlight() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(
                groupIdHex: groupIdHex,
                archived: false,
                selfMembership: .member,
                leaveRequestPending: true
            )
        )
        let model = GroupDetailsViewModel()
        var deleteRequested = false

        model.conversation = conversation
        model.deleteGroupLocalForTesting = { _, _ in
            deleteRequested = true
            return true
        }

        await model.deleteLocal(using: appState, dismiss: {})

        #expect(!deleteRequested)
        #expect(model.actionError == GroupManagementPresentation.leavingGroupComposerMessage)
    }

    /// A departed chat keeps `leaveRequestPending` until some remaining member
    /// commits the removal, which may never happen. Withholding the local delete
    /// there left the chat with no action that could clear its "Leaving" state.
    @Test func deleteLocalStaysAvailableAfterDepartureWithAnUncommittedLeave() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let groupIdHex = String(repeating: "ab", count: 32)
        let conversation = ConversationViewModel(
            appState: appState,
            group: archiveTestGroup(
                groupIdHex: groupIdHex,
                archived: false,
                selfMembership: .left,
                leaveRequestPending: true
            )
        )
        let model = GroupDetailsViewModel()
        var deleteRequested = false
        var dismissed = false

        model.conversation = conversation
        model.deleteGroupLocalForTesting = { _, _ in
            deleteRequested = true
            return true
        }

        await model.deleteLocal(using: appState, dismiss: { dismissed = true })

        #expect(deleteRequested)
        #expect(dismissed)
        #expect(model.actionError == nil)
    }
}

private enum GroupImageTestError: Error {
    case clearFailed
}

@MainActor
private final class GroupArchivePublishProbe {
    struct Request: Equatable {
        let accountRef: String
        let groupIdHex: String
        let archived: Bool
    }

    private(set) var requests: [Request] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCompletion: CheckedContinuation<AppGroupRecordFfi, Error>?

    func publish(accountRef: String, groupIdHex: String, archived: Bool) async throws -> AppGroupRecordFfi {
        let request = Request(accountRef: accountRef, groupIdHex: groupIdHex, archived: archived)
        requests.append(request)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        // If the production guard regresses, do not hang the test on a second
        // blocked continuation; return a record and let the request-count
        // assertion fail clearly.
        guard requests.count == 1 else {
            return archiveTestGroup(groupIdHex: groupIdHex, archived: archived)
        }

        return try await withCheckedThrowingContinuation { continuation in
            firstCompletion = continuation
        }
    }

    func waitUntilStarted() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func completeFirst(with record: AppGroupRecordFfi) {
        firstCompletion?.resume(returning: record)
        firstCompletion = nil
    }
}

@MainActor
private final class GroupProfilePublishProbe {
    struct Request: Equatable {
        let accountRef: String
        let groupIdHex: String
        let name: String
        let description: String
    }

    private(set) var requests: [Request] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCompletion: CheckedContinuation<SendSummaryFfi, Error>?

    func publish(
        accountRef: String,
        groupIdHex: String,
        name: String,
        description: String
    ) async throws -> SendSummaryFfi {
        let request = Request(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            name: name,
            description: description
        )
        requests.append(request)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        guard requests.count == 1 else {
            return SendSummaryFfi(published: 0, messageIds: [])
        }

        return try await withCheckedThrowingContinuation { continuation in
            firstCompletion = continuation
        }
    }

    func waitUntilStarted() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func completeFirst() {
        firstCompletion?.resume(returning: SendSummaryFfi(published: 1, messageIds: ["message-1"]))
        firstCompletion = nil
    }
}

@MainActor
private final class GroupAvatarPublishProbe {
    struct Request: Equatable {
        let accountRef: String
        let groupIdHex: String
        let data: Data
        let mediaType: String
    }

    private(set) var requests: [Request] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCompletion: CheckedContinuation<SendSummaryFfi, Error>?

    func publish(
        accountRef: String,
        groupIdHex: String,
        data: Data,
        mediaType: String
    ) async throws -> SendSummaryFfi {
        let request = Request(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            data: data,
            mediaType: mediaType
        )
        requests.append(request)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        guard requests.count == 1 else {
            return SendSummaryFfi(published: 0, messageIds: [])
        }

        return try await withCheckedThrowingContinuation { continuation in
            firstCompletion = continuation
        }
    }

    func waitUntilStarted() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func completeFirst() {
        firstCompletion?.resume(returning: SendSummaryFfi(published: 1, messageIds: ["message-1"]))
        firstCompletion = nil
    }
}

private func archiveTestGroup(
    groupIdHex: String,
    archived: Bool,
    selfMembership: SelfMembershipFfi = .member,
    leaveRequestPending: Bool = false,
    description: String = "",
    avatarUrl: String? = nil
) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: groupIdHex,
        endpoint: "",
        name: "Archive Test Group",
        description: description,
        admins: [],
        relays: [],
        nostrGroupIdHex: String(repeating: "cd", count: 32),
        avatarUrl: avatarUrl,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: EncryptedMediaVersionFfi.v1.wireValue,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net"),
            ]
        ),
        archived: archived,
        pendingConfirmation: false,
        selfMembership: selfMembership,
        leaveRequestPending: leaveRequestPending,
        leaveRequestedAtMs: leaveRequestPending ? 1_000 : nil,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func disbandManagementState(
    disbandingEnabled: Bool = false,
    canEnableDisbanding: Bool = false,
    canDisband: Bool = false
) -> GroupManagementStateFfi {
    GroupManagementStateFfi(
        myAccountIdHex: String(repeating: "11", count: 32),
        isSelfAdmin: true,
        isLastAdmin: true,
        canInvite: true,
        canLeave: false,
        requiresSelfDemoteBeforeLeave: false,
        leaveRequestPending: false,
        leaveRequestedAtMs: nil,
        lifecycleState: .stable,
        disbandingEnabled: disbandingEnabled,
        disbanding: false,
        canEnableDisbanding: canEnableDisbanding,
        canDisband: canDisband,
        disbandingBlockers: [],
        disbandRequest: nil,
        memberActions: []
    )
}
