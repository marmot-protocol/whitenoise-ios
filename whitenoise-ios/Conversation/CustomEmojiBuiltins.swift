import CryptoKit
import Foundation
import UIKit

// Built-in `:marmot:`, `:wn:` and the `:marmot_*:` emoji, the PNG bytes White
// Noise for Android and Linux are adopting. Untagged text renders them
// from the app bundle; a message or reaction using one carries the image like
// any custom emoji, so clients without them still see it.

/// One built-in emoji: its shortcode, spoken name and bundled PNG bytes.
nonisolated struct CustomEmojiBuiltin: Hashable, Sendable {
    /// What VoiceOver reads in place of the shortcode.
    enum Name: Hashable, Sendable {
        /// A product name, not translated (as on Android).
        case product(String)
        /// A string catalog key, read in the app language when spoken.
        case localized(String)
    }

    let shortcode: CustomEmojiShortcode
    let name: Name
    let data: Data
    let plaintextSha256: String
    let dim: String?

    var fileName: String { "\(shortcode.name).png" }
    var mediaType: String { "image/png" }

    var spokenName: String {
        switch name {
        case .product(let name): name
        case .localized(let key): L10n.string(String.LocalizationValue(key))
        }
    }

    init(shortcode: CustomEmojiShortcode, name: Name, data: Data, dim: String?) {
        self.shortcode = shortcode
        self.name = name
        self.data = data
        self.dim = dim
        plaintextSha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CustomEmojiBuiltins {
    private struct Definition {
        let shortcode: String
        let asset: String
        let name: CustomEmojiBuiltin.Name
    }

    // Keys must match Shared/Localizable.xcstrings.
    private static let definitions = [
        Definition(shortcode: "marmot", asset: "BuiltinEmojiMarmot", name: .product("Marmot")),
        Definition(shortcode: "wn", asset: "BuiltinEmojiWN", name: .product("White Noise")),
        Definition(shortcode: "marmot_classic", asset: "BuiltinEmojiMarmotClassic", name: .localized("Classic marmot")),
        Definition(shortcode: "marmot_wave", asset: "BuiltinEmojiMarmotWave", name: .localized("Waving marmot")),
        Definition(shortcode: "marmot_yes", asset: "BuiltinEmojiMarmotYes", name: .localized("Marmot thumbs up")),
        Definition(shortcode: "marmot_laugh", asset: "BuiltinEmojiMarmotLaugh", name: .localized("Laughing marmot")),
        Definition(shortcode: "marmot_love", asset: "BuiltinEmojiMarmotLove", name: .localized("Marmot with heart")),
        Definition(shortcode: "marmot_party", asset: "BuiltinEmojiMarmotParty", name: .localized("Party marmot")),
        Definition(shortcode: "marmot_fire", asset: "BuiltinEmojiMarmotFire", name: .localized("Marmot on fire")),
        Definition(shortcode: "marmot_wow", asset: "BuiltinEmojiMarmotWow", name: .localized("Surprised marmot")),
        Definition(shortcode: "marmot_smirk", asset: "BuiltinEmojiMarmotSmirk", name: .localized("Smirking marmot")),
        Definition(shortcode: "marmot_cry", asset: "BuiltinEmojiMarmotCry", name: .localized("Crying marmot")),
        Definition(shortcode: "marmot_angry", asset: "BuiltinEmojiMarmotAngry", name: .localized("Angry marmot")),
    ]

    /// Every built-in whose bundled bytes load, in picker order.
    static let all: [CustomEmojiBuiltin] = definitions.compactMap { definition in
        guard let shortcode = CustomEmojiShortcode(definition.shortcode),
              let data = NSDataAsset(name: definition.asset)?.data, !data.isEmpty else { return nil }
        let size = UIImage(data: data)?.cgImage.map { "\($0.width)x\($0.height)" }
        return CustomEmojiBuiltin(shortcode: shortcode, name: definition.name, data: data, dim: size)
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
