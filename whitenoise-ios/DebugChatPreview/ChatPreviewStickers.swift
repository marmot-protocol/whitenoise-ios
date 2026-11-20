#if DEBUG
import Foundation
import MarmotKit

nonisolated enum ChatPreviewStickers {
    private static let pack = "30031:\(ChatPreviewThread.peer):field-notes"

    static func reference(from author: String) -> StickerRefFfi? {
        let name = author == ChatPreviewThread.owner ? "marmot_yes" : "marmot_wave"
        guard let shortcode = CustomEmojiShortcode(name), let art = CustomEmojiBuiltins.builtin(shortcode) else { return nil }
        return StickerRefFfi(packCoordinate: pack, shortcode: name, plaintextSha256: art.plaintextSha256)
    }

    @MainActor
    static func store() -> StickerAssetStore {
        StickerAssetStore(
            scopeProvider: { StickerScope(accountRef: ChatPreviewThread.owner, runtimeGeneration: 0) },
            fetch: { _, ref in
                guard ref.packCoordinate == pack,
                      ["marmot_yes", "marmot_wave"].contains(ref.shortcode),
                      let shortcode = CustomEmojiShortcode(ref.shortcode),
                      let art = CustomEmojiBuiltins.builtin(shortcode),
                      art.plaintextSha256 == ref.plaintextSha256 else { throw URLError(.fileDoesNotExist) }
                let sticker = StickerFfi(packCoordinate: pack, shortcode: ref.shortcode,
                    url: "https://stickers.invalid/\(art.fileName)", plaintextSha256: art.plaintextSha256,
                    mime: art.mediaType, width: 128, height: 128, alt: art.spokenName, emoji: nil)
                return StickerAssetFfi(sticker: sticker, bytes: art.data)
            })
    }
}
#endif
