import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ContactNicknameStoreTests {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dev.ipf.WhiteNoise.contact-nickname-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test func keyNormalizesCaseAndWhitespace() throws {
        let key = try #require(ContactNicknameStore.key(
            ownerAccountIdHex: "  ABCDEF01  ",
            contactAccountIdHex: "\tFF00AA11\n"
        ))
        #expect(key == ContactNicknameStore.key(ownerAccountIdHex: "abcdef01", contactAccountIdHex: "ff00aa11"))
    }

    @Test func keyRejectsBlankComponents() {
        #expect(ContactNicknameStore.key(ownerAccountIdHex: "", contactAccountIdHex: "ff00") == nil)
        #expect(ContactNicknameStore.key(ownerAccountIdHex: "   ", contactAccountIdHex: "ff00") == nil)
        #expect(ContactNicknameStore.key(ownerAccountIdHex: "abcd", contactAccountIdHex: "") == nil)
        #expect(ContactNicknameStore.key(ownerAccountIdHex: "abcd", contactAccountIdHex: " \n") == nil)
    }

    @Test func keySeparatesOwnersAndContacts() {
        #expect(
            ContactNicknameStore.key(ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a")
                != ContactNicknameStore.key(ownerAccountIdHex: "owner-2", contactAccountIdHex: "contact-a")
        )
        #expect(
            ContactNicknameStore.key(ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a")
                != ContactNicknameStore.key(ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-b")
        )
        // The separator keeps the owner/contact boundary unambiguous.
        #expect(
            ContactNicknameStore.key(ownerAccountIdHex: "ab", contactAccountIdHex: "cd")
                != ContactNicknameStore.key(ownerAccountIdHex: "abc", contactAccountIdHex: "d")
        )
    }

    @Test func roundTripIsScopedToOwnerAndContactAndCaseInsensitive() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ContactNicknameStore.setNickname(
            "Bestie", ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        )

        #expect(ContactNicknameStore.nickname(
            ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        ) == "Bestie")
        #expect(ContactNicknameStore.nickname(
            ownerAccountIdHex: "OWNER-1", contactAccountIdHex: "CONTACT-A", defaults: defaults
        ) == "Bestie")
        #expect(ContactNicknameStore.nickname(
            ownerAccountIdHex: "owner-2", contactAccountIdHex: "contact-a", defaults: defaults
        ) == nil)
        #expect(ContactNicknameStore.nickname(
            ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-b", defaults: defaults
        ) == nil)
    }

    @Test func emptyOrBlankNicknameClearsTheEntry() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ContactNicknameStore.setNickname(
            "Bestie", ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        )
        ContactNicknameStore.setNickname(
            "   \n\t ", ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        )

        #expect(ContactNicknameStore.nickname(
            ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        ) == nil)
        #expect(ContactNicknameStore.nicknamesByKey(defaults: defaults).isEmpty)
    }

    @Test func nicknameIsSanitizedOnWriteAndRead() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A bidi-override control character is stripped like any display name.
        ContactNicknameStore.setNickname(
            "Ali\u{202E}ce", ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        )
        #expect(ContactNicknameStore.nickname(
            ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        ) == "Alice")

        // Overlong input is capped at the display-name grapheme bound.
        let long = String(repeating: "x", count: ContentSanitizer.maxNameLength + 40)
        ContactNicknameStore.setNickname(
            long, ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        )
        let stored = try #require(ContactNicknameStore.nickname(
            ownerAccountIdHex: "owner-1", contactAccountIdHex: "contact-a", defaults: defaults
        ))
        #expect(stored.count == ContentSanitizer.maxNameLength)
    }

    @Test func clearAllRemovesOnlyTheOwnersNicknames() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ContactNicknameStore.setNickname("A1", ownerAccountIdHex: "owner-1", contactAccountIdHex: "c-a", defaults: defaults)
        ContactNicknameStore.setNickname("A2", ownerAccountIdHex: "owner-1", contactAccountIdHex: "c-b", defaults: defaults)
        ContactNicknameStore.setNickname("B1", ownerAccountIdHex: "owner-2", contactAccountIdHex: "c-a", defaults: defaults)

        ContactNicknameStore.clearAll(ownerAccountIdHex: "OWNER-1", defaults: defaults)

        #expect(ContactNicknameStore.nickname(ownerAccountIdHex: "owner-1", contactAccountIdHex: "c-a", defaults: defaults) == nil)
        #expect(ContactNicknameStore.nickname(ownerAccountIdHex: "owner-1", contactAccountIdHex: "c-b", defaults: defaults) == nil)
        #expect(ContactNicknameStore.nickname(ownerAccountIdHex: "owner-2", contactAccountIdHex: "c-a", defaults: defaults) == "B1")
    }

    @Test func snapshotLookupMatchesStoreReads() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ContactNicknameStore.setNickname("Bestie", ownerAccountIdHex: "owner-1", contactAccountIdHex: "c-a", defaults: defaults)
        ContactNicknameStore.setNickname("Boss", ownerAccountIdHex: "owner-2", contactAccountIdHex: "c-b", defaults: defaults)

        let snapshot = ContactNicknameStore.nicknamesByKey(defaults: defaults)

        #expect(snapshot.count == 2)
        #expect(ContactNicknameStore.nickname(ownerAccountIdHex: "owner-1", contactAccountIdHex: "c-a", in: snapshot) == "Bestie")
        #expect(ContactNicknameStore.nickname(ownerAccountIdHex: "OWNER-2", contactAccountIdHex: "c-b", in: snapshot) == "Boss")
        #expect(ContactNicknameStore.nickname(ownerAccountIdHex: "owner-1", contactAccountIdHex: "c-b", in: snapshot) == nil)
        #expect(ContactNicknameStore.nickname(ownerAccountIdHex: "", contactAccountIdHex: "c-a", in: snapshot) == nil)
    }

    @Test func unresolvedSharedSuiteDegradesWithoutWritingAnotherDomain() {
        #expect(ContactNicknameStore.nicknamesByKey(defaults: nil).isEmpty)
        #expect(ContactNicknameStore.nickname(
            ownerAccountIdHex: "owner-1",
            contactAccountIdHex: "contact-a",
            defaults: nil
        ) == nil)

        ContactNicknameStore.setNickname(
            "Bestie",
            ownerAccountIdHex: "owner-1",
            contactAccountIdHex: "contact-a",
            defaults: nil
        )
        ContactNicknameStore.clearAll(ownerAccountIdHex: "owner-1", defaults: nil)

        #expect(ContactNicknameStore.nicknamesByKey(defaults: nil).isEmpty)
    }
}

struct ContactNicknameOwnerGateTests {

    @Test func noActiveAccountMeansNoOwner() {
        #expect(AppState.contactNicknameOwner(
            activeAccountIdHex: nil,
            localAccountIdsHex: ["aa"],
            contactAccountIdHex: "cc"
        ) == nil)
        #expect(AppState.contactNicknameOwner(
            activeAccountIdHex: "",
            localAccountIdsHex: ["aa"],
            contactAccountIdHex: "cc"
        ) == nil)
    }

    @Test func blankContactHasNoOwner() {
        #expect(AppState.contactNicknameOwner(
            activeAccountIdHex: "aa",
            localAccountIdsHex: ["aa"],
            contactAccountIdHex: "   "
        ) == nil)
    }

    @Test func ownAccountsCannotBeNicknamed() {
        // A contact that is one of this device's own accounts (case-insensitive)
        // keeps its local label; no nickname owner is produced.
        #expect(AppState.contactNicknameOwner(
            activeAccountIdHex: "aa",
            localAccountIdsHex: ["aa", "bb"],
            contactAccountIdHex: "BB"
        ) == nil)
    }

    @Test func otherContactsResolveToTheActiveOwner() {
        #expect(AppState.contactNicknameOwner(
            activeAccountIdHex: "aa",
            localAccountIdsHex: ["aa", "bb"],
            contactAccountIdHex: "cc"
        ) == "aa")
    }
}

@MainActor
struct ContactNicknameResolutionTests {

    private func nicknameDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dev.ipf.WhiteNoise.contact-nickname-resolution.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private func profile(displayName: String) -> UserProfileMetadataFfi {
        UserProfileMetadataFfi(
            name: nil, displayName: displayName, about: nil, picture: nil, banner: nil, nip05: nil, lud16: nil
        )
    }

    @Test func nicknameOverridesResolvedProfileNameEverywhere() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let (defaults, suiteName) = try nicknameDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        appState.profileStore.contactNicknameDefaults = defaults

        let ownerHex = String(repeating: "aa", count: 32)
        let peerHex = String(repeating: "cc", count: 32)
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "me", accountIdHex: ownerHex, localSigning: true, signedOut: false, running: true)
        ]
        appState.activeAccountRef = "me"
        // Seed a resolved projection so the chokepoint has a real profile name
        // to fall back to (cache hit avoids scheduling a relay load).
        appState.profileStore.profileProjectionCache[peerHex] = ProfileDisplayProjection(
            profile: profile(displayName: "Real Name"),
            projectedName: nil,
            localAccountLabel: nil
        )

        // Before any nickname, the chokepoint resolves the profile name.
        #expect(appState.knownDisplayName(forAccountIdHex: peerHex) == "Real Name")
        #expect(appState.knownProfileDisplayName(forAccountIdHex: peerHex) == "Real Name")

        appState.setContactNickname("Bestie", forAccountIdHex: peerHex)

        // The nickname wins at the single resolution layer, so displayName and
        // knownDisplayName (chat titles, mentions, member lists, notifications)
        // all pick it up; the real profile name stays available as secondary.
        #expect(appState.knownDisplayName(forAccountIdHex: peerHex) == "Bestie")
        #expect(appState.displayName(forAccountIdHex: peerHex) == "Bestie")
        #expect(appState.contactNickname(forAccountIdHex: peerHex) == "Bestie")
        #expect(appState.knownProfileDisplayName(forAccountIdHex: peerHex) == "Real Name")

        // Clearing restores the profile-resolved name.
        appState.setContactNickname("", forAccountIdHex: peerHex)
        #expect(appState.contactNickname(forAccountIdHex: peerHex) == nil)
        #expect(appState.knownDisplayName(forAccountIdHex: peerHex) == "Real Name")
    }

    @Test func cannotSetNicknameForOwnAccount() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let (defaults, suiteName) = try nicknameDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        appState.profileStore.contactNicknameDefaults = defaults

        let ownerHex = String(repeating: "aa", count: 32)
        let otherLocalHex = String(repeating: "bb", count: 32)
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "me", accountIdHex: ownerHex, localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "alt", accountIdHex: otherLocalHex, localSigning: true, signedOut: false, running: true)
        ]
        appState.activeAccountRef = "me"

        appState.setContactNickname("Myself", forAccountIdHex: otherLocalHex)

        #expect(appState.contactNickname(forAccountIdHex: otherLocalHex) == nil)
        #expect(ContactNicknameStore.nicknamesByKey(defaults: defaults).isEmpty)
    }
}

struct ContactNicknameNotificationProjectionTests {

    @Test func nicknameOverridesSenderNameInNotificationTitle() {
        let ownerHex = String(repeating: "aa", count: 32)
        let senderHex = String(repeating: "22", count: 32)
        let update = nicknameNotificationUpdate(ownerAccountIdHex: ownerHex, senderAccountIdHex: senderHex)

        // Baseline: no resolver keeps the kind:0 sender name.
        #expect(LocalNotificationProjection.makePresentation(for: update)?.title == "Alice")

        // With a matching (owner, sender) nickname, the title uses the override.
        let withNickname = LocalNotificationProjection.makePresentation(for: update) { owner, contact in
            owner == ownerHex && contact == senderHex ? "Bestie" : nil
        }
        #expect(withNickname?.title == "Bestie")
    }

    @Test func serviceDecisionThreadsNicknameToPrimaryPresentation() {
        let ownerHex = String(repeating: "aa", count: 32)
        let senderHex = String(repeating: "22", count: 32)
        let update = nicknameNotificationUpdate(ownerAccountIdHex: ownerHex, senderAccountIdHex: senderHex)
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [update],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection, nickname: { owner, contact in
            owner == ownerHex && contact == senderHex ? "Bestie" : nil
        })

        guard case let .decorate(primary, _) = decision else {
            Issue.record("expected a decorate decision")
            return
        }
        #expect(primary.title == "Bestie")
    }
}

private func nicknameNotificationUpdate(
    ownerAccountIdHex: String,
    senderAccountIdHex: String
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: "notif-1",
        conversationKey: "conv-1",
        trigger: .newMessage,
        accountRef: "account-a",
        accountIdHex: ownerAccountIdHex,
        groupIdHex: "group-a",
        groupName: nil,
        isDm: true,
        isMention: false,
        messageIdHex: "message-1",
        sender: NotificationUserFfi(
            accountIdHex: senderAccountIdHex,
            displayName: "Alice",
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: ownerAccountIdHex,
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: "hello",
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: 1_000,
        isFromSelf: false
    )
}
