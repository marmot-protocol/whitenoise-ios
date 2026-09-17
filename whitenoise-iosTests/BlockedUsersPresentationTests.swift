import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct BlockedUsersPresentationTests {
    @Test func rowsOrderByDisplayNameAndKeepIdentityStableAcrossRepublication() {
        let users = [
            blocked("cc"),
            blocked("aa"),
            blocked("bb"),
        ]

        let rows = BlockedUsersPresentation.rows(
            users: users,
            displayName: { ["aa": "Zoe", "bb": "alice", "cc": "Bob"][$0] ?? $0 },
            npub: { "npub-\($0)" }
        )

        #expect(rows.map(\.displayName) == ["alice", "Bob", "Zoe"])
        #expect(rows.map(\.accountIdHex) == ["bb", "cc", "aa"])
        #expect(rows.map(\.id) == rows.map(\.accountIdHex))

        let reordered = BlockedUsersPresentation.rows(
            users: users.reversed(),
            displayName: { ["aa": "Zoe", "bb": "alice", "cc": "Bob"][$0] ?? $0 },
            npub: { "npub-\($0)" }
        )
        #expect(reordered == rows)
    }

    @Test func rowsBreakDisplayNameTiesOnAccountIdSoOrderIsDeterministic() {
        let rows = BlockedUsersPresentation.rows(
            users: [blocked("ff"), blocked("0a")],
            displayName: { _ in "Anonymous" },
            npub: { _ in nil }
        )

        #expect(rows.map(\.accountIdHex) == ["0a", "ff"])
        #expect(rows.allSatisfy { $0.npub == nil })
    }

    /// MDK can list the same key twice (a private and a public entry). A
    /// duplicated row id would make `ForEach` render the person twice and
    /// unblock an ambiguous row.
    @Test func rowsDeduplicateRepeatedKeysCaseInsensitively() {
        let rows = BlockedUsersPresentation.rows(
            users: [
                blocked("AB12", isPrivate: false),
                blocked("ab12", isPrivate: true),
                blocked("cd34"),
            ],
            displayName: { _ in "Peer" },
            npub: { _ in nil }
        )

        #expect(rows.map(\.accountIdHex) == ["ab12", "cd34"])
    }

    @Test func blockingIsOfferedForAPeerButNeverForThisDevicesOwnProfiles() {
        let mine = ["AAAA", "bbbb"]

        #expect(BlockedUsersPresentation.canBlock(targetAccountIdHex: "cccc", localAccountIdHexes: mine))
        #expect(!BlockedUsersPresentation.canBlock(targetAccountIdHex: "aaaa", localAccountIdHexes: mine))
        #expect(!BlockedUsersPresentation.canBlock(targetAccountIdHex: "BBBB", localAccountIdHexes: mine))
    }

    /// The target is resolved asynchronously, so the control must stay hidden
    /// until there is a key to publish rather than flashing an inert button.
    @Test func blockingIsWithheldUntilTheReferenceResolves() {
        #expect(!BlockedUsersPresentation.canBlock(targetAccountIdHex: nil, localAccountIdHexes: []))
        #expect(!BlockedUsersPresentation.canBlock(targetAccountIdHex: "", localAccountIdHexes: []))
    }

    /// The row stays on screen and goes inert: hiding it turned a suspended
    /// runtime or a failed read into a surface with no block affordance at all.
    @Test func theBlockActionIsInertUntilTheLiveListHasArrived() {
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: false, publishingIsBlocking: nil, hasUncertainIntent: false,
            isBlocked: false, targetAccountIdHex: "cccc"
        ) == .inert(isBlocked: false))
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: nil, hasUncertainIntent: false,
            isBlocked: false, targetAccountIdHex: "cccc"
        ) == .ready(isBlocked: false))
    }

    /// Greying out says only "busy". Naming the direction tells the user which
    /// of the two things they just asked for is on its way.
    @Test func aTappedMutationNamesItsDirectionInsteadOfGoingInert() {
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: true, hasUncertainIntent: false,
            isBlocked: false, targetAccountIdHex: "cccc"
        ) == .publishing(isBlocking: true))
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: false, hasUncertainIntent: false,
            isBlocked: true, targetAccountIdHex: "cccc"
        ) == .publishing(isBlocking: false))
    }

    /// Retrying an unconfirmed publication is still a publication; it must read
    /// as in-flight rather than falling back to the held-inert state.
    @Test func publishingOutranksAnUnconfirmedPublicationHold() {
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: nil, hasUncertainIntent: true,
            isBlocked: false, targetAccountIdHex: "cccc"
        ) == .inert(isBlocked: false))
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: true, hasUncertainIntent: true,
            isBlocked: false, targetAccountIdHex: "cccc"
        ) == .publishing(isBlocking: true))
    }

    /// The label has to follow the live list, so an already-blocked person is
    /// offered Unblock rather than a second Block.
    @Test func theOfferedActionFollowsTheLiveBlockState() {
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: nil, hasUncertainIntent: false,
            isBlocked: true, targetAccountIdHex: "cccc"
        ) == .ready(isBlocked: true))
    }

    @Test func anUnresolvedReferenceHasNoKeyToPublishSoTheActionStaysInert() {
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: nil, hasUncertainIntent: false,
            isBlocked: false, targetAccountIdHex: nil
        ) == .inert(isBlocked: false))
        #expect(BlockedUsersPresentation.blockAction(
            isLoaded: true, publishingIsBlocking: nil, hasUncertainIntent: false,
            isBlocked: false, targetAccountIdHex: ""
        ) == .inert(isBlocked: false))
    }

    /// The inbox preview is the last place a blocked peer's words would still
    /// reach the screen once the conversation stopped showing them.
    @Test func aDirectChatWithABlockedPeerReplacesItsPreview() {
        #expect(BlockedUsersPresentation.showsBlockedPeerPreview(
            isDirectMessage: true, directPeerAccountIdHex: "CCCC", blockedAccountIds: ["cccc"]
        ))
        #expect(!BlockedUsersPresentation.showsBlockedPeerPreview(
            isDirectMessage: true, directPeerAccountIdHex: "dddd", blockedAccountIds: ["cccc"]
        ))
    }

    /// A blocked member is one voice among many in a group, so the row still
    /// belongs to the group and keeps its own preview.
    @Test func aGroupRowKeepsItsPreviewEvenWhenAMemberIsBlocked() {
        #expect(!BlockedUsersPresentation.showsBlockedPeerPreview(
            isDirectMessage: false, directPeerAccountIdHex: "cccc", blockedAccountIds: ["cccc"]
        ))
        #expect(!BlockedUsersPresentation.showsBlockedPeerPreview(
            isDirectMessage: nil, directPeerAccountIdHex: "cccc", blockedAccountIds: ["cccc"]
        ))
        #expect(!BlockedUsersPresentation.showsBlockedPeerPreview(
            isDirectMessage: true, directPeerAccountIdHex: nil, blockedAccountIds: ["cccc"]
        ))
    }

    private func blocked(_ publicKey: String, isPrivate: Bool = false) -> BlockedUserFfi {
        BlockedUserFfi(publicKey: publicKey, isPrivate: isPrivate, createdAtMs: 0)
    }
}
