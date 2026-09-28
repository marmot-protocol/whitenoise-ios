import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct ConversationChoiceProjectionTests {
    private let me = String(repeating: "aa", count: 32)
    private let alice = String(repeating: "bb", count: 32)
    private let bob = String(repeating: "cc", count: 32)

    @Test func includesNamedUnnamedAndArchivedTwoPersonConversationsByRecency() {
        let unnamed = snapshot(
            groupIdHex: "unnamed",
            name: nil,
            members: [me, alice],
            lastActivityAt: 20
        )
        let named = snapshot(
            groupIdHex: "named",
            name: "Trip planning",
            members: [alice, me],
            lastActivityAt: 30
        )
        let archived = snapshot(
            groupIdHex: "archived",
            name: nil,
            members: [me, alice],
            isArchived: true,
            lastActivityAt: 10
        )

        let choices = ConversationChoiceProjection.choices(
            in: [unnamed, archived, named],
            targetAccountIdHex: alice,
            myAccountIdHex: me
        )

        #expect(choices.map(\.groupIdHex) == ["named", "unnamed", "archived"])
        #expect(choices.first?.name == "Trip planning")
        #expect(choices.last?.isArchived == true)
    }

    @Test func ignoresConversationKindButRequiresAnExactActiveTwoPersonRoster() {
        let namedGroup = snapshot(
            groupIdHex: "named-group",
            name: "Pair",
            members: [me, alice],
            conversationKind: .group,
            lastActivityAt: 30
        )
        let larger = snapshot(
            groupIdHex: "larger",
            name: nil,
            members: [me, alice, bob],
            lastActivityAt: 40
        )
        let left = snapshot(
            groupIdHex: "left",
            name: nil,
            members: [me, alice],
            isSelfMember: false,
            lastActivityAt: 50
        )
        let wrongPeer = snapshot(
            groupIdHex: "wrong-peer",
            name: nil,
            members: [me, bob],
            lastActivityAt: 60
        )

        let choices = ConversationChoiceProjection.choices(
            in: [larger, left, wrongPeer, namedGroup],
            targetAccountIdHex: alice,
            myAccountIdHex: me
        )

        #expect(choices.map(\.groupIdHex) == ["named-group"])
    }

    @Test func matchingIsCaseInsensitiveAndTieOrderingIsStable() {
        let second = snapshot(
            groupIdHex: "b",
            name: nil,
            members: [me.uppercased(), alice],
            lastActivityAt: 10
        )
        let first = snapshot(
            groupIdHex: "a",
            name: nil,
            members: [alice.uppercased(), me],
            lastActivityAt: 10
        )

        let choices = ConversationChoiceProjection.choices(
            in: [second, first],
            targetAccountIdHex: alice,
            myAccountIdHex: me
        )

        #expect(choices.map(\.groupIdHex) == ["a", "b"])
    }

    @Test func startNewConversationCreatesEvenWhenExistingChoicesArePresent() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account"
        let model = NewChatFlowViewModel()
        model.conversationChooser = chooser()
        var createdMemberRef: String?
        model.starter.createGroupForTesting = { _, memberRef in
            createdMemberRef = memberRef
            return "new-conversation"
        }
        var openedGroupIdHex: String?

        await model.startNewConversation(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(createdMemberRef == alice)
        #expect(openedGroupIdHex == "new-conversation")
        #expect(model.conversationChooser == nil)
    }

    @Test func openingAChoiceNeverCreatesAnotherGroup() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account"
        let model = NewChatFlowViewModel()
        let chooser = chooser()
        model.conversationChooser = chooser
        model.starter.createGroupForTesting = { _, _ in
            Issue.record("opening an existing choice must not create")
            throw TestFailure.unexpectedCreate
        }
        var openedGroupIdHex: String?

        await model.openConversation(
            chooser.choices[0],
            using: appState
        ) {
            openedGroupIdHex = $0
        }

        #expect(openedGroupIdHex == "existing")
        #expect(model.conversationChooser == nil)
    }

    @Test func retryAfterStartNewFailureRetriesTheExactCreateIntent() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account"
        let model = NewChatFlowViewModel()
        model.conversationChooser = chooser()
        var lookupCount = 0
        model.existingDirectChatGroupIdForTesting = { _ in
            lookupCount += 1
            return "existing"
        }
        var createCount = 0
        model.starter.createGroupForTesting = { _, _ in
            createCount += 1
            if createCount == 1 {
                throw TestFailure.createFailed
            }
            return "new-after-retry"
        }
        var openedGroupIdHex: String?

        await model.startNewConversation(using: appState) { _ in }
        #expect(model.startPrompt != nil)

        await model.retryStart(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(lookupCount == 0)
        #expect(createCount == 2)
        #expect(openedGroupIdHex == "new-after-retry")
    }

    private func snapshot(
        groupIdHex: String,
        name: String?,
        members: [String],
        isArchived: Bool = false,
        isSelfMember: Bool = true,
        conversationKind: ChatConversationKindFfi = .direct,
        lastActivityAt: UInt64
    ) -> RecipientGroupSnapshot {
        RecipientGroupSnapshot(
            groupIdHex: groupIdHex,
            sanitizedName: name,
            title: name ?? "Alice",
            avatarUrl: nil,
            isArchived: isArchived,
            isSelfMember: isSelfMember,
            conversationKind: conversationKind,
            lastActivityAt: lastActivityAt,
            memberIdsHex: members,
            lastSenderIdHex: nil,
            welcomerIdHex: nil
        )
    }

    private func chooser() -> ConversationChooserPresentation {
        ConversationChooserPresentation(
            targetAccountIdHex: alice,
            memberRef: alice,
            recipientName: "Alice",
            choices: [
                ConversationChoice(
                    groupIdHex: "existing",
                    name: nil,
                    avatarUrl: nil,
                    imageHashHex: nil,
                    isArchived: false,
                    lastActivityAt: 10
                )
            ]
        )
    }

    private enum TestFailure: Error {
        case unexpectedCreate
        case createFailed
    }
}
