import Foundation

/// Normalizes the six user-configurable quick reactions. Variation selectors
/// do not make otherwise-identical glyphs distinct, matching Android.
nonisolated enum QuickReactionChoices {
    static let limit = 6

    static func normalize(
        _ choices: [String],
        defaults: [String] = AppState.defaultReactions
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in choices + defaults {
            let emoji = ContentSanitizer.reactionEmoji(raw)
            guard !emoji.isEmpty else { continue }
            let identity = identity(of: emoji)
            guard seen.insert(identity).inserted else { continue }
            result.append(emoji)
            if result.count == limit { break }
        }
        return result
    }

    /// Replaces one quick-reaction slot without disturbing the other choices.
    /// Selecting a reaction already present in another slot swaps the two so
    /// the six-choice invariant is preserved without silently backfilling a
    /// default reaction.
    static func replacing(
        _ choices: [String],
        at index: Int,
        with rawChoice: String,
        defaults: [String] = AppState.defaultReactions
    ) -> [String] {
        var result = normalize(choices, defaults: defaults)
        guard result.indices.contains(index) else { return result }
        let choice = ContentSanitizer.reactionEmoji(rawChoice)
        guard !choice.isEmpty else { return result }

        let choiceIdentity = identity(of: choice)
        if let existingIndex = result.firstIndex(where: { identity(of: $0) == choiceIdentity }) {
            if existingIndex != index {
                result.swapAt(existingIndex, index)
            }
        } else {
            result[index] = choice
        }
        return result
    }

    static func recentChoices(
        recent: [String],
        defaults: [String] = AppState.defaultReactions
    ) -> [String] {
        normalize(recent, defaults: defaults)
    }

    static func resolved(
        customized: [String]?,
        recent: [String],
        defaults: [String] = AppState.defaultReactions
    ) -> [String] {
        customized.map { normalize($0, defaults: defaults) }
            ?? recentChoices(recent: recent, defaults: defaults)
    }

    private static func identity(of emoji: String) -> String {
        emoji.unicodeScalars
            .filter { $0.value != 0xFE0E && $0.value != 0xFE0F }
            .map(String.init)
            .joined()
    }
}

/// Keeps the persistence contract independently testable without constructing
/// the full application runtime.
enum QuickReactionPreferences {
    static let key = "marmot.quickReactions"

    static func load(from defaults: UserDefaults) -> [String]? {
        defaults.stringArray(forKey: key)
            .map { QuickReactionChoices.normalize($0) }
    }

    @discardableResult
    static func save(_ choices: [String], to defaults: UserDefaults) -> [String] {
        let normalized = QuickReactionChoices.normalize(choices)
        HostSettingsSaveTiming.measure { defaults.set(normalized, forKey: key) }
        return normalized
    }
}
