import Foundation
import Testing
@testable import whitenoise_ios

struct QuickReactionChoicesTests {
    @Test func quickReactionChoicesAreStableUniqueAndFilledToSix() {
        #expect(QuickReactionChoices.normalize(["🔥", "🔥", "\u{202E}", "👍"]) == [
            "🔥", "👍", "❤️", "👎", "😂", "😮",
        ])
        #expect(QuickReactionChoices.normalize(["❤", "❤️"]).filter { $0 == "❤" || $0 == "❤️" }.count == 1)
    }

    @Test func choosingAnExistingQuickReactionSwapsOnlyTheTwoSlots() {
        let choices = ["❤️", "👍", "👎", "😂", "😮", "😢"]

        #expect(QuickReactionChoices.replacing(choices, at: 0, with: "😂") == [
            "😂", "👍", "👎", "❤️", "😮", "😢",
        ])
        #expect(QuickReactionChoices.replacing(choices, at: 1, with: "🔥") == [
            "❤️", "🔥", "👎", "😂", "😮", "😢",
        ])
    }

    @Test func customizedQuickReactionsPersistAndOverrideRecents() throws {
        let suiteName = "QuickReactionChoicesTests.quickReactions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(QuickReactionChoices.resolved(
            customized: nil,
            recent: ["🔥"]
        ) == ["🔥", "❤️", "👍", "👎", "😂", "😮"])

        let saved = QuickReactionPreferences.save(
            ["🚀", "✅", "🎉", "👀", "🙏", "💯"],
            to: defaults
        )
        let reloaded = QuickReactionPreferences.load(from: defaults)

        #expect(reloaded == saved)
        #expect(QuickReactionChoices.resolved(
            customized: reloaded,
            recent: ["🔥", "😢"]
        ) == saved)

        let reset = QuickReactionPreferences.save(AppState.defaultReactions, to: defaults)
        #expect(QuickReactionPreferences.load(from: defaults) == AppState.defaultReactions)
        #expect(QuickReactionChoices.resolved(
            customized: reset,
            recent: ["🔥"]
        ) == AppState.defaultReactions)
    }
}
