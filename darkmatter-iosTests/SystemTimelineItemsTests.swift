import Foundation
import Testing
@testable import darkmatter_ios
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

        #expect(retained == [duplicate])
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
            appState: AppState(client: try MarmotClient.testClient()),
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
}

private func testGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: String(repeating: "bb", count: 32),
        endpoint: "",
        name: "Test Group",
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: "",
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
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
            ]
        ),
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}
