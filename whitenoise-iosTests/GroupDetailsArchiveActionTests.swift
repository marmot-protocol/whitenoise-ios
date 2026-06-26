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

private func archiveTestGroup(groupIdHex: String, archived: Bool) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: groupIdHex,
        endpoint: "",
        name: "Archive Test Group",
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: String(repeating: "cd", count: 32),
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: MessageSemantics.encryptedMediaVersion,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net"),
            ]
        ),
        archived: archived,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}
