import CryptoKit
import Foundation
import UIKit

// Built-in `:marmot:` and `:wn:`, the same PNG bytes White Noise for Android
// and Linux ship. Untagged text renders them from the app bundle; a message
// or reaction using one carries the image like any custom emoji, so clients
// without them still see it.

/// One built-in emoji: its shortcode, product name and bundled PNG bytes.
nonisolated struct CustomEmojiBuiltin: Hashable, Sendable {
    let shortcode: CustomEmojiShortcode
    /// Product name read by VoiceOver in place of the shortcode.
    let spokenName: String
    let data: Data
    let plaintextSha256: String
    let dim: String?

    var fileName: String { "\(shortcode.name).png" }
    var mediaType: String { "image/png" }

    init(shortcode: CustomEmojiShortcode, spokenName: String, data: Data, dim: String?) {
        self.shortcode = shortcode
        self.spokenName = spokenName
        self.data = data
        self.dim = dim
        plaintextSha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CustomEmojiBuiltins {
    private struct Definition {
        let shortcode: String
        let asset: String
        let spokenName: String
    }

    // Product names, not translated (as on Android).
    private static let definitions = [
        Definition(shortcode: "marmot", asset: "BuiltinEmojiMarmot", spokenName: "Marmot"),
        Definition(shortcode: "wn", asset: "BuiltinEmojiWN", spokenName: "White Noise"),
    ]

    /// Every built-in whose bundled bytes load, in picker order.
    static let all: [CustomEmojiBuiltin] = definitions.compactMap { definition in
        guard let shortcode = CustomEmojiShortcode(definition.shortcode),
              let data = NSDataAsset(name: definition.asset)?.data, !data.isEmpty else { return nil }
        let size = UIImage(data: data)?.cgImage.map { "\($0.width)x\($0.height)" }
        return CustomEmojiBuiltin(shortcode: shortcode, spokenName: definition.spokenName, data: data, dim: size)
    }

    static let shortcodes = Set(all.map(\.shortcode))

    static func builtin(_ shortcode: CustomEmojiShortcode) -> CustomEmojiBuiltin? {
        all.first { $0.shortcode == shortcode }
    }

    /// The VoiceOver name for an inline or reaction shortcode.
    static func spokenName(_ shortcode: CustomEmojiShortcode) -> String {
        builtin(shortcode)?.spokenName ?? shortcode.name
    }
}

/// Decoded built-in images, sized to a point size like loaded custom emoji.
@MainActor
enum CustomEmojiBuiltinImages {
    private static var decoded: [CustomEmojiShortcode: UIImage] = [:]
    private static var sized: [SizedKey: UIImage] = [:]

    private struct SizedKey: Hashable {
        let shortcode: CustomEmojiShortcode
        let pixelSize: Int
        let scale: CGFloat
    }

    static func image(for shortcode: CustomEmojiShortcode, pixelSize: Int, scale: CGFloat) -> UIImage? {
        let key = SizedKey(shortcode: shortcode, pixelSize: pixelSize, scale: scale)
        if let cached = sized[key] { return cached }
        guard let image = original(shortcode) else { return nil }
        let result = ConversationCustomEmojiStore.sizedToPoints(image, pixelSize: pixelSize, scale: scale)
        sized[key] = result
        return result
    }

    private static func original(_ shortcode: CustomEmojiShortcode) -> UIImage? {
        if let cached = decoded[shortcode] { return cached }
        guard let builtin = CustomEmojiBuiltins.builtin(shortcode), let image = UIImage(data: builtin.data) else { return nil }
        decoded[shortcode] = image
        return image
    }
}
