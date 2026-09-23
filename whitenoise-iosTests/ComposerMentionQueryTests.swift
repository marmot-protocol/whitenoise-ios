import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

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

    @MainActor
    @Test func detailedRosterCandidatePrefersLocalContactNickname() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let suiteName = "dev.ipf.WhiteNoise.mention-nickname.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        appState.profileStore.contactNicknameDefaults = defaults
        let ownerHex = String(repeating: "aa", count: 32)
        let peerHex = String(repeating: "bb", count: 32)
        appState.accountStore.accounts = [
            AccountSummaryFfi(
                label: "me",
                accountIdHex: ownerHex,
                localSigning: true,
                signedOut: false,
                running: true
            )
        ]
        appState.activeAccountRef = "me"
        appState.setContactNickname("Bestie", forAccountIdHex: peerHex)
        let details = GroupMemberDetailsFfi(
            memberIdHex: peerHex,
            account: peerHex,
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: "Peer profile name"
        )

        let candidate = ComposerMentionCandidate(details: details, appState: appState)

        #expect(candidate.displayName == "Bestie")
        #expect(ComposerMentionQuery.filter([candidate], matching: "best").map(\.npub) == [aliceNpub])
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

    @Test func replacingInsertsDisplayNameMention() throws {
        let draft = "ping @je"
        let session = try #require(ComposerMentionQuery.active(in: draft))
        let updated = ComposerMentionQuery.replacing(session: session, in: draft, with: "Jeff")
        #expect(updated == "ping @Jeff ")
    }

    @Test func canonicalizeDisplayNameMentionForSend() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111")
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates
        )
        #expect(outgoing == "ping @\(jeffNpub) ")
    }

    @Test func canonicalizeRefusesAmbiguousNamesWithoutASelection() {
        // Two members share the display name: without an explicit tap, the
        // mention stays literal text — a peer cloning a name cannot capture
        // an unselected mention through match ordering.
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates
        )
        #expect(outgoing == "ping @Jeff ")
    }

    @Test func canonicalizeResolvesAmbiguousNamesThroughTheTappedIdentity() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates,
            selectedMentions: [ComposerMentionSelection(
                utf16Location: "ping ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: aliceNpub
            )]
        )
        #expect(outgoing == "ping @\(aliceNpub) ")
    }

    @Test func editProjectionRendersNamesAndPreservesAmbiguousIdentities() throws {
        let firstNpub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let secondNpub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "22", count: 32)
        ))
        let canonical = "ask @\(firstNpub) then @\(secondNpub)"
        let projection = CanonicalMentionDisplayProjection.project(canonical) { npub in
            [firstNpub, secondNpub].contains(npub) ? "Alex" : nil
        }

        #expect(projection.text == "ask @Alex then @Alex")
        #expect(projection.selectedMentions.map(\.npub) == [firstNpub, secondNpub])
        #expect(projection.selectedMentions.map(\.utf16Location) == [
            "ask ".utf16.count,
            "ask @Alex then ".utf16.count,
        ])

        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            projection.text,
            candidates: [
                mentionCandidate(name: "Alex", npub: firstNpub, hex: "111"),
                mentionCandidate(name: "Alex", npub: secondNpub, hex: "222"),
            ],
            selectedMentions: projection.selectedMentions
        )
        #expect(outgoing == canonical)
    }

    @Test func editProjectionLeavesNonMentionsAndUnknownProfilesCanonical() throws {
        let knownNpub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let unknownNpub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "22", count: 32)
        ))
        let overlongNpub = "npub1\(String(repeating: "q", count: 59))"
        let text = "mail me@\(knownNpub), ping @\(unknownNpub), reject @\(overlongNpub)"
        let projection = CanonicalMentionDisplayProjection.project(text) { npub in
            npub == knownNpub ? "Alex" : nil
        }

        #expect(projection.text == text)
        #expect(projection.selectedMentions.isEmpty)
    }

    @Test func boundedCanonicalizationNeverSplitsExpandedMention() {
        let candidate = mentionCandidate(name: "Alex", npub: aliceNpub, hex: "111")
        let prefix = String(repeating: "x", count: ContentSanitizer.maxMessageLength - 6)
        let text = "\(prefix) @Alex"

        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            text,
            candidates: [candidate],
            maxLength: ContentSanitizer.maxMessageLength
        )

        #expect(outgoing == "\(prefix) ")
        #expect(!outgoing.contains("@npub"))
    }

    @Test func boundedCanonicalizationKeepsMentionWholeWhenItFitsExactly() {
        let candidate = mentionCandidate(name: "Alex", npub: aliceNpub, hex: "111")
        let canonicalMention = "@\(aliceNpub)"
        let prefix = String(
            repeating: "x",
            count: ContentSanitizer.maxMessageLength - canonicalMention.count - 1
        )

        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "\(prefix) @Alex",
            candidates: [candidate],
            maxLength: ContentSanitizer.maxMessageLength
        )

        #expect(outgoing.count == ContentSanitizer.maxMessageLength)
        #expect(outgoing.hasSuffix(canonicalMention))
    }

    @Test func ambiguousSelectionsStayBoundToTheirOwnOccurrences() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
        ]
        let secondLocation = "@Jeff and ".utf16.count
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "@Jeff and @Jeff",
            candidates: candidates,
            selectedMentions: [
                ComposerMentionSelection(
                    utf16Location: 0,
                    utf16Length: "@Jeff".utf16.count,
                    displayName: "Jeff",
                    npub: jeffNpub
                ),
                ComposerMentionSelection(
                    utf16Location: secondLocation,
                    utf16Length: "@Jeff".utf16.count,
                    displayName: "Jeff",
                    npub: aliceNpub
                ),
            ]
        )

        #expect(outgoing == "@\(jeffNpub) and @\(aliceNpub)")
    }

    @Test func deletedSelectionDoesNotBindRetypedAmbiguousText() {
        let original = "ping @Jeff "
        var selections = [ComposerMentionSelection(
            utf16Location: "ping ".utf16.count,
            utf16Length: "@Jeff".utf16.count,
            displayName: "Jeff",
            npub: aliceNpub
        )]
        selections = ComposerMentionSelectionTracker.reconcile(selections, from: original, to: "ping ")
        selections = ComposerMentionSelectionTracker.reconcile(selections, from: "ping ", to: original)

        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            original,
            candidates: [
                mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
                mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
            ],
            selectedMentions: selections
        )

        #expect(selections.isEmpty)
        #expect(outgoing == original)
    }

    @Test func deletingOneOfTwoIdenticalMentionsDropsAmbiguousBindings() {
        let original = "@Jeff x @Jeff"
        let selections = [
            ComposerMentionSelection(
                utf16Location: 0,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: jeffNpub
            ),
            ComposerMentionSelection(
                utf16Location: "@Jeff x ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: aliceNpub
            ),
        ]

        let reconciled = ComposerMentionSelectionTracker.reconcile(
            selections,
            from: original,
            to: "@Jeff"
        )
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "@Jeff",
            candidates: [
                mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
                mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
            ],
            selectedMentions: reconciled
        )

        #expect(reconciled.isEmpty)
        #expect(outgoing == "@Jeff")
    }

    @Test func canonicalizeIgnoresSelectionsPointingOutsideTheRoster() {
        // A stale selection whose npub no longer belongs to any member with
        // that name must not resolve the mention.
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates,
            selectedMentions: [ComposerMentionSelection(
                utf16Location: "ping ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: "npub1notinroster"
            )]
        )
        #expect(outgoing == "ping @Jeff ")
    }

    @Test func selectedMentionDoesNotRetargetToAReplacementNamesake() {
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: [
                mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            ],
            selectedMentions: [ComposerMentionSelection(
                utf16Location: "ping ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: aliceNpub
            )]
        )

        #expect(outgoing == "ping @Jeff ")
    }

    @Test func selectedMentionSurvivesProfileRename() {
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: [
                mentionCandidate(name: "Jeffrey", npub: jeffNpub, hex: "111"),
            ],
            selectedMentions: [ComposerMentionSelection(
                utf16Location: "ping ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: jeffNpub
            )]
        )

        #expect(outgoing == "ping @\(jeffNpub) ")
    }

    @Test func restoredSelectedMentionSurvivesUnresolvedRoster() throws {
        let selectedNpub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: [],
            selectedMentions: [ComposerMentionSelection(
                utf16Location: "ping ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: selectedNpub
            )],
            rosterResolution: .unresolved
        )

        #expect(outgoing == "ping @\(selectedNpub) ")
    }

    @Test func unresolvedRosterRejectsMalformedPersistedIdentity() {
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: [],
            selectedMentions: [ComposerMentionSelection(
                utf16Location: "ping ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: "npub1invalid"
            )],
            rosterResolution: .unresolved
        )

        #expect(outgoing == "ping @Jeff ")
    }

    @Test func restoredSelectedMentionFailsClosedAgainstResolvedEmptyRoster() {
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: [],
            selectedMentions: [ComposerMentionSelection(
                utf16Location: "ping ".utf16.count,
                utf16Length: "@Jeff".utf16.count,
                displayName: "Jeff",
                npub: jeffNpub
            )]
        )

        #expect(outgoing == "ping @Jeff ")
    }

    @Test func canonicalizeDisplayNameMentionWithSpacesAndPunctuation() {
        let candidates = [
            mentionCandidate(name: "Jeff Smith", npub: jeffNpub, hex: "111")
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping (@Jeff Smith), are you around?",
            candidates: candidates
        )
        #expect(outgoing == "ping (@\(jeffNpub)), are you around?")
    }

    @Test func canonicalizePrefersLongestDisplayName() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff Smith", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff Smith ",
            candidates: candidates
        )
        #expect(outgoing == "ping @\(aliceNpub) ")
    }

    @Test func canonicalizeKeepsNonMentionAtSignsAndLongerWords() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111")
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "mail me@Jeff or ping @Jefferson or open /@Jeff",
            candidates: candidates
        )
        #expect(outgoing == "mail me@Jeff or ping @Jefferson or open /@Jeff")
    }

    @Test func hidesAutocompleteForCompleteNpubBody() {
        let partial = "npub1" + String(repeating: "q", count: 57)
        #expect(!ComposerMentionQuery.looksLikeCompleteNpub(partial))
        #expect(ComposerMentionQuery.looksLikeCompleteNpub(jeffNpub))
    }

    @Test func groupMemberDetailsProfileLookupsUseNostrMemberId() {
        let member = GroupMemberDetailsFfi(
            memberIdHex: "nostr-account-id",
            account: "local-account-label",
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: nil
        )

        #expect(
            GroupMemberDetailsPresentation.profileAccountIdHex(for: member) == "nostr-account-id")
    }

    @Test func groupMemberDetailsProfileLookupsUseNostrMemberIdWithoutAccountLabel() {
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

    @Test func fallbackMemberCandidateEncodesNpubWithoutMarmotClient() throws {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let accountIdHex = try #require(NostrProfileReference.pubkeyHex(fromBech32: npub))
        let member = AppGroupMemberRecordFfi(
            memberIdHex: "mls-member-id",
            account: accountIdHex,
            local: false
        )

        let candidate = try #require(ComposerMentionCandidate(member: member, appState: AppState()))

        #expect(candidate.npub == npub)
        #expect(candidate.displayName == IdentityFormatter.short(npub))
    }

    @Test func fallbackMemberCandidateRejectsInvalidAccountHex() {
        let member = AppGroupMemberRecordFfi(
            memberIdHex: "mls-member-id",
            account: "account-label",
            local: false
        )

        #expect(ComposerMentionCandidate(member: member, appState: AppState()) == nil)
    }

    @Test func mentionCandidateCacheKeyTreatsSameGenerationsAsEqual() {
        // Regression for #300: ConversationViewModel caches the `@`-mention
        // candidate list and reuses it across keystrokes, rebuilding only when
        // the roster or profile generation changes. Equal generation pairs must
        // compare equal so the cache is reused (no per-keystroke rebuild).
        let a = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 3)
        let b = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 3)
        #expect(a == b)
    }

    @Test func mentionCandidateCacheKeyInvalidatesWhenEitherGenerationChanges() {
        // A bump in either the roster generation (membership/admin change) or
        // the profile generation (resolved display name/avatar/npub) must make
        // the key compare unequal so a freshly resolved candidate list is built.
        let base = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 3)
        let rosterBumped = MentionCandidateCacheKey(
            rosterGeneration: 8, profileGeneration: 3)
        let profileBumped = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 4)
        #expect(base != rosterBumped)
        #expect(base != profileBumped)
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
