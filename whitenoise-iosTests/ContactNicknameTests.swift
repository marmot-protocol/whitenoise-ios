import Foundation
import Testing

@testable import whitenoise_ios

struct LegacyContactNicknameCleanupTests {
    @Test func erasureRemovesOnlyTheDepartingOwnersLegacyEntries() throws {
        let suite = "LegacyNicknames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "owner-a:peer-a": "Old nickname",
            "owner-a:peer-b": "Another nickname",
            "owner-b:peer-a": "Other account"
        ], forKey: ContactNicknameStore.storageKey)

        ContactNicknameStore.clearAll(ownerAccountIdHex: " OWNER-A ", defaults: defaults)

        #expect(defaults.dictionary(forKey: ContactNicknameStore.storageKey) as? [String: String]
            == ["owner-b:peer-a": "Other account"])
    }

    @Test func unavailableDefaultsAndEmptyOwnersAreSafe() throws {
        let suite = "LegacyNicknames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["owner:peer": "Old nickname"], forKey: ContactNicknameStore.storageKey)

        ContactNicknameStore.clearAll(ownerAccountIdHex: "owner", defaults: nil)
        ContactNicknameStore.clearAll(ownerAccountIdHex: " ", defaults: defaults)

        #expect(defaults.dictionary(forKey: ContactNicknameStore.storageKey) as? [String: String]
            == ["owner:peer": "Old nickname"])
    }
}
