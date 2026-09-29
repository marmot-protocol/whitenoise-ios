import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct SystemTimelineItemsTests {
    @Test func retainedSystemTimelineItemsDeduplicateConsecutiveEvents() {
        let first = TimelineItem.systemEvent(id: "first", event: .rosterChanged, timestamp: 1)
        let duplicate = TimelineItem.systemEvent(id: "duplicate", event: .rosterChanged, timestamp: 2)

        let retained = ConversationViewModel.retainedSystemTimelineItems(
            [first],
            appending: duplicate,
            limit: 8
        )

        #expect(retained.map(\.id) == [first.id])
        #expect(retained.first?.timestamp == duplicate.timestamp)
    }

    @Test func retainedSystemTimelineItemsKeepDistinctSeparatedEvents() {
        let first = TimelineItem.systemEvent(id: "first", event: .rosterChanged, timestamp: 1)
        let archive = TimelineItem.systemEvent(id: "archive", event: .groupArchived, timestamp: 2)
        let second = TimelineItem.systemEvent(id: "second", event: .rosterChanged, timestamp: 3)

        let retained = ConversationViewModel.retainedSystemTimelineItems(
            [first, archive],
            appending: second,
            limit: 8
        )

        #expect(retained == [first, archive, second])
    }

    @Test func retainedSystemTimelineItemsCapsOldestRows() {
        let items = (0..<3).map {
            TimelineItem.systemEvent(id: "old-\($0)", event: .groupRenamed("Name \($0)"), timestamp: UInt64($0))
        }
        let newest = TimelineItem.systemEvent(id: "newest", event: .groupArchived, timestamp: 99)

        let retained = ConversationViewModel.retainedSystemTimelineItems(
            items,
            appending: newest,
            limit: 2
        )

        #expect(retained.map(\.id) == [items[2].id, newest.id])
    }

    @Test func resetOptimisticStateClearsSessionSystemTimelineRows() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: testGroup()
        )

        viewModel.appendSystemEventForTesting(.rosterChanged, timestamp: 1)
        #expect(viewModel.timeline.contains { item in
            if case .systemEvent(.rosterChanged) = item.kind { return true }
            return false
        })

        viewModel.resetOptimisticStateForTesting()

        #expect(!viewModel.timeline.contains { item in
            if case .systemEvent = item.kind { return true }
            return false
        })
    }

    @Test func consecutiveSameKindSystemEventPublishesUpdatedTimestamp() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: testGroup()
        )

        viewModel.appendSystemEventForTesting(.rosterChanged, timestamp: 1)
        viewModel.appendSystemEventForTesting(.rosterChanged, timestamp: 2)

        // The two same-kind events collapse into one row, and the published
        // timeline row must carry the newer timestamp — not the stale first one.
        let systemRows = viewModel.timeline.filter { item in
            if case .systemEvent(.rosterChanged) = item.kind { return true }
            return false
        }
        #expect(systemRows.count == 1)
        #expect(systemRows.first?.timestamp == 2)
    }

    @Test func resetOptimisticStateClearsTransientMessageRows() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: testGroup().groupIdHex,
            sender: String(repeating: "a", count: 64),
            plaintext: "pending",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 1,
            receivedAt: 1
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending", record: pending)
        #expect(!viewModel.timeline.isEmpty)

        viewModel.resetOptimisticStateForTesting()

        #expect(viewModel.timeline.isEmpty)
    }

    @Test func groupSnapshotChangesRefreshDurableTimelineRows() {
        let admins = Set(["admin-a"])
        #expect(!ConversationViewModel.groupSnapshotNeedsTimelineTailRefresh(
            previousName: "Test Group",
            previousArchived: false,
            previousAdmins: admins,
            next: testGroup(admins: ["admin-a"])
        ))
        #expect(ConversationViewModel.groupSnapshotNeedsTimelineTailRefresh(
            previousName: "Test Group",
            previousArchived: false,
            previousAdmins: admins,
            next: testGroup(name: "Renamed", admins: ["admin-a"])
        ))
        #expect(!ConversationViewModel.groupSnapshotNeedsTimelineTailRefresh(
            previousName: "",
            previousArchived: false,
            previousAdmins: admins,
            next: testGroup(name: "Initial snapshot", admins: ["admin-a"])
        ))
        #expect(ConversationViewModel.groupSnapshotNeedsTimelineTailRefresh(
            previousName: "Test Group",
            previousArchived: false,
            previousAdmins: admins,
            next: testGroup(admins: ["admin-a"], archived: true)
        ))
        #expect(ConversationViewModel.groupSnapshotNeedsTimelineTailRefresh(
            previousName: "Test Group",
            previousArchived: false,
            previousAdmins: admins,
            next: testGroup(admins: ["admin-a", "admin-b"])
        ))
        #expect(ConversationViewModel.groupSnapshotNeedsTimelineTailRefresh(
            previousName: "Test Group",
            previousArchived: false,
            previousAdmins: admins,
            next: testGroup(admins: ["admin-a"], disbanding: true)
        ))
        #expect(ConversationViewModel.groupSnapshotNeedsTimelineTailRefresh(
            previousName: "Test Group",
            previousArchived: false,
            previousAdmins: admins,
            next: testGroup(admins: ["admin-a"], disbanded: true)
        ))
    }

    @Test func groupMembershipChangesRefreshDurableTimelineRows() {
        #expect(!ConversationViewModel.groupMembersNeedTimelineTailRefresh(
            previousMemberIds: ["alice", "bob"],
            nextMemberIds: ["alice", "bob"]
        ))
        #expect(ConversationViewModel.groupMembersNeedTimelineTailRefresh(
            previousMemberIds: ["alice"],
            nextMemberIds: ["alice", "bob"]
        ))
        #expect(ConversationViewModel.groupMembersNeedTimelineTailRefresh(
            previousMemberIds: ["alice", "bob"],
            nextMemberIds: ["bob", "alice"]
        ))
    }
}

private func testGroup(
    name: String = "Test Group",
    admins: [String] = [],
    archived: Bool = false,
    disbanding: Bool = false,
    disbanded: Bool = false
) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: String(repeating: "bb", count: 32),
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
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: EncryptedMediaVersionFfi.v1.wireValue,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
            ]
        ),
        archived: archived,
        pendingConfirmation: false,
        disbanding: disbanding,
        disbanded: disbanded,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}
