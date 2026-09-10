import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

/// A real 32-byte key and its canonical npub, so assertions compare against a
/// value that was not produced by the code under test.
private enum Fixture {
    static let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkd7y72z35mp4dam5svjhxk4"
    static let hex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c114166f89e50a34d86adeee9"
    static let otherHex = String(repeating: "ab", count: 32)
    static let otherNpub = "npub14w46h2at4w46h2at4w46h2at4w46h2at4w46h2at4w46h2at4w4scf6zts"
}

private func containsHex(_ text: String, _ hex: String) -> Bool {
    let lowercased = text.lowercased()
    if lowercased.contains(hex.lowercased()) { return true }
    // A middle-truncated hex leaks its head and tail, which is what shipped
    // before this contract existed.
    let head = hex.prefix(8).lowercased()
    let tail = hex.suffix(6).lowercased()
    return lowercased.contains(head) || lowercased.contains(tail)
}

struct IdentityPresentationContractTests {

    struct Case {
        let label: String
        let accountIdHex: String?
        let knownName: String?
        let expectedSource: IdentityPresentation.Source
        let expectedText: String?
    }

    @Test func resolvesEveryInputShapeWithoutLeakingHex() {
        let cases: [Case] = [
            Case(
                label: "nickname wins",
                accountIdHex: Fixture.hex,
                knownName: "Nickname",
                expectedSource: .name,
                expectedText: "Nickname"
            ),
            Case(
                label: "sanitized profile name",
                accountIdHex: Fixture.hex,
                knownName: "  Bob\u{202E}  ",
                expectedSource: .name,
                expectedText: "Bob"
            ),
            Case(
                label: "blank name falls through to npub",
                accountIdHex: Fixture.hex,
                knownName: "   ",
                expectedSource: .npub,
                expectedText: IdentityFormatter.short(Fixture.npub)
            ),
            Case(
                label: "unknown valid key",
                accountIdHex: Fixture.hex,
                knownName: nil,
                expectedSource: .npub,
                expectedText: IdentityFormatter.short(Fixture.npub)
            ),
            Case(
                label: "uppercase valid hex normalizes",
                accountIdHex: Fixture.hex.uppercased(),
                knownName: nil,
                expectedSource: .npub,
                expectedText: IdentityFormatter.short(Fixture.npub)
            ),
            Case(
                label: "surrounding whitespace normalizes",
                accountIdHex: "  \(Fixture.hex)\n",
                knownName: nil,
                expectedSource: .npub,
                expectedText: IdentityFormatter.short(Fixture.npub)
            ),
            Case(
                label: "too short",
                accountIdHex: String(Fixture.hex.dropLast()),
                knownName: nil,
                expectedSource: .unknown,
                expectedText: nil
            ),
            Case(
                label: "too long",
                accountIdHex: Fixture.hex + "ab",
                knownName: nil,
                expectedSource: .unknown,
                expectedText: nil
            ),
            Case(
                label: "non-hex characters",
                accountIdHex: String(repeating: "zz", count: 32),
                knownName: nil,
                expectedSource: .unknown,
                expectedText: nil
            ),
            Case(
                label: "fullwidth digits are not hex",
                accountIdHex: String(repeating: "\u{FF10}", count: 64),
                knownName: nil,
                expectedSource: .unknown,
                expectedText: nil
            ),
            Case(
                label: "empty",
                accountIdHex: "",
                knownName: nil,
                expectedSource: .unknown,
                expectedText: nil
            ),
            Case(
                label: "nil",
                accountIdHex: nil,
                knownName: nil,
                expectedSource: .unknown,
                expectedText: nil
            ),
            Case(
                label: "malformed key still yields a name when one is known",
                accountIdHex: "not-a-key",
                knownName: "Carol",
                expectedSource: .name,
                expectedText: "Carol"
            ),
        ]

        for testCase in cases {
            let resolved = IdentityPresentation.resolve(
                accountIdHex: testCase.accountIdHex,
                knownName: testCase.knownName
            )
            #expect(resolved.source == testCase.expectedSource, "\(testCase.label)")
            if let expectedText = testCase.expectedText {
                #expect(resolved.text == expectedText, "\(testCase.label)")
            }
            #expect(!resolved.text.isEmpty, "\(testCase.label)")
            #expect(!containsHex(resolved.text, Fixture.hex), "\(testCase.label)")
            if let accountIdHex = testCase.accountIdHex, accountIdHex.count > 12 {
                #expect(!resolved.text.contains(accountIdHex), "\(testCase.label)")
            }
        }
    }

    @Test func malformedKeyIsNeverEchoedAndIsNotLabelledNpub() {
        let malformed = "deadbeefnotavalidkey"
        let resolved = IdentityPresentation.resolve(accountIdHex: malformed)

        #expect(resolved.source == .unknown)
        #expect(!resolved.text.contains(malformed))
        #expect(!resolved.text.lowercased().contains("npub"))
    }

    @Test func unknownFallbackStylesDiffer() {
        let user = IdentityPresentation.resolve(accountIdHex: nil, unknown: .user)
        let sender = IdentityPresentation.resolve(accountIdHex: nil, unknown: .sender)

        #expect(user.text != sender.text)
        #expect(user.source == .unknown)
        #expect(sender.source == .unknown)
    }

    @Test func abbreviationOnlyChangesHowMuchOfTheNpubShows() {
        let short = IdentityPresentation.text(accountIdHex: Fixture.hex, abbreviation: .short)
        let wide = IdentityPresentation.text(accountIdHex: Fixture.hex, abbreviation: .wide)
        let full = IdentityPresentation.text(accountIdHex: Fixture.hex, abbreviation: .full)

        #expect(full == Fixture.npub)
        #expect(short.count < wide.count)
        #expect(wide.count < full.count)
        for text in [short, wide, full] {
            #expect(text.hasPrefix("npub1"))
            #expect(!containsHex(text, Fixture.hex))
        }
    }

    @Test func canonicalNpubRejectsMalformedInputInsteadOfReturningIt() {
        #expect(IdentityPresentation.canonicalNpub(accountIdHex: Fixture.hex) == Fixture.npub)
        #expect(IdentityPresentation.canonicalNpub(accountIdHex: Fixture.hex.uppercased()) == Fixture.npub)
        #expect(IdentityPresentation.canonicalNpub(accountIdHex: nil) == nil)
        #expect(IdentityPresentation.canonicalNpub(accountIdHex: "") == nil)
        #expect(IdentityPresentation.canonicalNpub(accountIdHex: "zz") == nil)
        #expect(IdentityPresentation.canonicalNpub(accountIdHex: Fixture.hex + "00") == nil)
    }

    @Test func canonicalNpubIsAlwaysLowercaseBech32() throws {
        let npub = try #require(IdentityPresentation.canonicalNpub(accountIdHex: Fixture.hex))

        #expect(npub == npub.lowercased())
        #expect(NostrProfileReference.pubkeyHex(fromBech32: npub) == Fixture.hex)
    }
}

/// Each adapter family is exercised through the same public entry point the UI
/// calls, so the assertion is about behavior rather than how the call site is
/// spelled.
@MainActor
struct IdentityPresentationAdapterTests {

    @Test func groupSystemEventsNameParticipantsByNpubWithoutAResolver() throws {
        let payload = """
        {"system_type":"member_added","data":{"actor":"\(Fixture.hex)","subject":"\(Fixture.otherHex)"}}
        """
        let text = try #require(GroupSystemEventPresentation.displayText(from: payload))

        #expect(text.contains("npub1"))
        #expect(!containsHex(text, Fixture.hex))
        #expect(!containsHex(text, Fixture.otherHex))
    }

    @Test func chatListPreviewsNameParticipantsByNpubWithoutAResolver() throws {
        let payload = """
        {"system_type":"member_removed","data":{"actor":"\(Fixture.hex)","subject":"\(Fixture.otherHex)"}}
        """
        let text = GroupSystemEventPresentation.displayText(
            from: payload,
            currentAccountIdHex: nil,
            displayName: GroupSystemEventNaming.unresolvedIdentities.displayName
        )
        let preview = try #require(text)

        #expect(preview.contains("npub1"))
        #expect(!containsHex(preview, Fixture.hex))
        #expect(!containsHex(preview, Fixture.otherHex))
    }

    @Test func groupSystemEventsWithMalformedParticipantsUseGenericCopy() throws {
        let payload = """
        {"system_type":"member_added","data":{"actor":"not-a-key","subject":"\(Fixture.otherHex)"}}
        """
        let text = try #require(GroupSystemEventPresentation.displayText(from: payload))

        #expect(!text.contains("not-a-key"))
    }

    @Test func notificationSenderFallsBackToNpubThenGenericCopy() throws {
        let unnamed = try #require(
            LocalNotificationProjection.makePresentation(
                for: notificationUpdate(senderAccountIdHex: Fixture.hex, senderName: nil)
            )
        )
        let unnamedSender = try #require(unnamed.senderName)
        #expect(unnamedSender.hasPrefix("npub1"))
        #expect(!containsHex(unnamedSender, Fixture.hex))
        #expect(!containsHex(unnamed.title, Fixture.hex))
        #expect(!containsHex(unnamed.body, Fixture.hex))

        let malformed = try #require(
            LocalNotificationProjection.makePresentation(
                for: notificationUpdate(senderAccountIdHex: "0011", senderName: nil)
            )
        )
        let malformedSender = try #require(malformed.senderName)
        #expect(!malformedSender.contains("0011"))
        #expect(!malformedSender.hasPrefix("npub1"))
    }

    @Test func notificationNicknameAndProfileNameStillWinOverNpub() throws {
        let named = try #require(
            LocalNotificationProjection.makePresentation(
                for: notificationUpdate(senderAccountIdHex: Fixture.hex, senderName: "Alice")
            )
        )
        #expect(named.senderName == "Alice")

        let nicknamed = try #require(
            LocalNotificationProjection.makePresentation(
                for: notificationUpdate(senderAccountIdHex: Fixture.hex, senderName: "Alice"),
                nickname: { _, _ in "Nickname" }
            )
        )
        #expect(nicknamed.senderName == "Nickname")
    }

    @Test func blankNotificationSenderNameDoesNotRenderEmpty() throws {
        let blank = try #require(
            LocalNotificationProjection.makePresentation(
                for: notificationUpdate(senderAccountIdHex: Fixture.hex, senderName: "   ")
            )
        )
        #expect(try #require(blank.senderName).hasPrefix("npub1"))
    }

    @Test func memberRowNamesUnknownMembersByNpub() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let member = GroupMemberDetailsFfi(
            memberIdHex: Fixture.hex,
            account: Fixture.hex,
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: Fixture.npub,
            displayName: nil
        )

        let name = GroupMemberDetailsPresentation.displayName(for: member, appState: appState)
        #expect(name.hasPrefix("npub1"))
        #expect(!containsHex(name, Fixture.hex))
    }

    @Test func stagedRecipientNamesUnknownMembersByNpub() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let member = MemberRefFfi(
            memberRef: Fixture.npub,
            accountIdHex: Fixture.hex,
            npub: Fixture.npub
        )

        let name = AddMembersPresentation.displayName(for: member, appState: appState)
        #expect(name.hasPrefix("npub1"))
        #expect(!containsHex(name, Fixture.hex))
    }

    @Test func directMessageChatTitleNamesUnknownPeerByNpub() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let title = appState.displayName(forAccountIdHex: Fixture.hex)

        #expect(title == IdentityFormatter.short(Fixture.npub))
        #expect(!containsHex(title, Fixture.hex))
    }

    @Test func copyableNpubIsWithheldRatherThanFallingBackToHex() throws {
        let appState = AppState(client: try MarmotClient.testClient())

        #expect(appState.npub(forAccountIdHex: Fixture.hex) == Fixture.npub)
        #expect(appState.npub(forAccountIdHex: "not-a-key") == nil)
        #expect(appState.npub(forAccountIdHex: "") == nil)
    }

    /// The reactive upgrade the issue describes: the first read has no profile
    /// (the cold/relaunch/notification-extension case) and must render an npub;
    /// a later profile promotes the same call to a name and never regresses.
    @Test func presentationUpgradesFromNpubToNameWithoutEverShowingHex() throws {
        let appState = AppState(client: try MarmotClient.testClient())

        let firstFrame = appState.displayName(forAccountIdHex: Fixture.hex)
        #expect(firstFrame.hasPrefix("npub1"))
        #expect(!containsHex(firstFrame, Fixture.hex))

        appState.seedDiscoveredProfile(
            UserProfileMetadataFfi(
                name: nil,
                displayName: "Hydrated Name",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            ),
            forAccountIdHex: Fixture.hex
        )

        let hydrated = appState.displayName(forAccountIdHex: Fixture.hex)
        #expect(hydrated == "Hydrated Name")
        #expect(!containsHex(hydrated, Fixture.hex))
    }
}

private func notificationUpdate(
    senderAccountIdHex: String,
    senderName: String?
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: "notif-identity",
        conversationKey: "conv-identity",
        trigger: .newMessage,
        accountRef: "account-identity",
        accountIdHex: String(repeating: "11", count: 32),
        groupIdHex: "group-identity",
        groupName: nil,
        isDm: true,
        isMention: false,
        messageIdHex: "message-identity",
        sender: NotificationUserFfi(
            accountIdHex: senderAccountIdHex,
            displayName: senderName,
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: String(repeating: "11", count: 32),
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: "Hello",
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: 1_700_000_000_123,
        isFromSelf: false
    )
}
