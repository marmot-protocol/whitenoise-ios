import Foundation
import MarmotKit

/// NIP-51 emoji sets (kind 30030). MDK owns discovery, the stored sets,
/// installed bytes and their validation. Reads are local; `fetchEmojiSet`
/// and `syncEmojiSets` contact relays (text only); asset, cover and install
/// calls download from the hosts a set's author chose.
extension MarmotClient {
    func emojiSet(accountRef: String, coordinate: String) async throws -> EmojiSetFfi? {
        try await marmot.emojiSet(accountRef: accountRef, coordinate: coordinate)
    }

    func emojiSets(accountRef: String, installedOnly: Bool, search: String?, limit: UInt32?) async throws -> [EmojiSetFfi] {
        try await marmot.emojiSets(accountRef: accountRef, installedOnly: installedOnly, search: search, limit: limit)
    }

    func syncEmojiSets(accountRef: String, search: String?) async throws -> EmojiSetSyncResultFfi {
        try await marmot.syncEmojiSets(accountRef: accountRef, search: search)
    }

    func fetchEmojiSet(accountRef: String, input: String) async throws -> EmojiSetFfi {
        try await marmot.fetchEmojiSet(accountRef: accountRef, input: input)
    }

    func fetchEmojiSetAsset(accountRef: String, coordinate: String, expectedEventIdHex: String,
                            shortcode: String) async throws -> EmojiSetAssetFfi {
        try await marmot.fetchEmojiSetAsset(accountRef: accountRef, coordinate: coordinate,
                                            expectedEventIdHex: expectedEventIdHex, shortcode: shortcode)
    }

    func installEmojiSet(accountRef: String, coordinate: String, expectedEventIdHex: String,
                         control: EmojiSetInstallControlFfi) async throws -> EmojiSetInstallResultFfi {
        try await marmot.installEmojiSet(accountRef: accountRef, coordinate: coordinate,
                                         expectedEventIdHex: expectedEventIdHex, control: control)
    }

    func uninstallEmojiSet(accountRef: String, coordinate: String) async throws -> Bool {
        try await marmot.uninstallEmojiSet(accountRef: accountRef, coordinate: coordinate)
    }

    func installedCustomEmoji(accountRef: String) async throws -> [InstalledCustomEmojiFfi] {
        try await marmot.installedCustomEmoji(accountRef: accountRef)
    }

    func readInstalledCustomEmoji(accountRef: String, coordinate: String, shortcode: String) async throws -> InstalledCustomEmojiAssetFfi {
        try await marmot.readInstalledCustomEmoji(accountRef: accountRef, coordinate: coordinate, shortcode: shortcode)
    }

    func userEmojiList(accountRef: String) async throws -> UserEmojiListFfi {
        try await marmot.userEmojiList(accountRef: accountRef)
    }
}
