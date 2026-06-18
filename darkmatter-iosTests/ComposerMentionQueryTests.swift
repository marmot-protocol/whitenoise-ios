import Foundation
import MarmotKit
import Testing

@testable import darkmatter_ios

struct ComposerMentionQueryTests {
    private let jeffNpub = "npub1" + String(repeating: "q", count: 58)
    private let aliceNpub = "npub1" + String(repeating: "a", count: 58)

    @Test func activeMentionFindsTrailingAtSignQuery() {
        let draft = "hey @je"
        let session = ComposerMentionQuery.active(in: draft)
        #expect(session?.query == "je")
    }

    @Test func activeMentionRequiresWordBoundaryBeforeAt() {
        #expect(ComposerMentionQuery.active(in: "email@jeff") == nil)
    }

    @Test func activeMentionEndsAtWhitespace() {
        #expect(ComposerMentionQuery.active(in: "hey @jeff there") == nil)
    }

    @Test func activeMentionAllowsAtStart() {
        let session = ComposerMentionQuery.active(in: "@al")
        #expect(session?.query == "al")
    }

    @Test func filterMatchesDisplayNameAndNpub() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Alice", npub: aliceNpub, hex: "222"),
        ]
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "je").map(\.displayName) == ["Jeff"])
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "npub1a").map(\.displayName) == [
                "Alice"
            ])
        #expect(ComposerMentionQuery.filter(candidates, matching: "").count == 2)
    }

    @Test func filterMatchesMemberIdHexCaseInsensitively() {
        // Regression for #300: filter matches against precomputed lowercased
        // fields. Verify the memberIdHex match path and case-insensitivity
        // survive the precompute (an uppercase query must still match the
        // cached lowercased hex).
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "deadbeef01"),
            mentionCandidate(name: "Alice", npub: aliceNpub, hex: "cafef00d02"),
        ]
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "DEADBEEF").map(\.displayName) == [
                "Jeff"
            ])
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "cafe").map(\.displayName) == [
                "Alice"
            ])
        #expect(ComposerMentionQuery.filter(candidates, matching: "JE").map(\.displayName) == ["Jeff"])
    }

    @Test func replacingInsertsFullNpubMention() throws {
        let draft = "ping @je"
        let session = try #require(ComposerMentionQuery.active(in: draft))
        let updated = ComposerMentionQuery.replacing(session: session, in: draft, with: jeffNpub)
        #expect(updated == "ping @\(jeffNpub) ")
    }

    @Test func hidesAutocompleteForCompleteNpubBody() {
        let partial = "npub1" + String(repeating: "q", count: 57)
        #expect(!ComposerMentionQuery.looksLikeCompleteNpub(partial))
        #expect(ComposerMentionQuery.looksLikeCompleteNpub(jeffNpub))
    }

    @Test func groupMemberDetailsProfileLookupsUseMappedAccountId() {
        let member = GroupMemberDetailsFfi(
            memberIdHex: "mls-member-id",
            account: "nostr-account-id",
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: nil
        )

        #expect(
            GroupMemberDetailsPresentation.profileAccountIdHex(for: member) == "nostr-account-id")
    }

    @Test func groupMemberDetailsProfileLookupsFallBackToMemberIdWithoutAccount() {
        let missingAccount = GroupMemberDetailsFfi(
            memberIdHex: "mls-member-id",
            account: nil,
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: nil
        )
        let emptyAccount = GroupMemberDetailsFfi(
            memberIdHex: "mls-member-id",
            account: "",
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: nil
        )

        #expect(
            GroupMemberDetailsPresentation.profileAccountIdHex(for: missingAccount)
                == "mls-member-id")
        #expect(
            GroupMemberDetailsPresentation.profileAccountIdHex(for: emptyAccount) == "mls-member-id"
        )
    }
}

private func mentionCandidate(name: String, npub: String, hex: String) -> ComposerMentionCandidate {
    ComposerMentionCandidate(
        details: GroupMemberDetailsFfi(
            memberIdHex: hex,
            account: hex,
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: npub,
            displayName: name
        ),
        appState: AppState()
    )
}
