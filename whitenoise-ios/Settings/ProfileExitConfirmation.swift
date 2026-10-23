import Foundation

nonisolated enum ProfileExitConfirmation {
    static func matches(_ input: String, expected: String) -> Bool {
        !expected.isEmpty && input.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    static func canSignOut(wiping: Bool, input: String, profileName: String, busy: Bool) -> Bool {
        !busy && (!wiping || (!profileName.isEmpty && input == profileName))
    }

    static func hasExtraSurroundingWhitespace(_ input: String, profileName: String) -> Bool {
        !profileName.isEmpty && input != profileName
            && input.trimmingCharacters(in: .whitespacesAndNewlines) == profileName
    }

    static func erasePhrase() -> String {
        let words = ["apple", "bird", "cloud", "dawn", "earth", "field", "green", "harbor", "island", "lake", "moon", "river"]
        return words.shuffled().prefix(3).joined(separator: " ")
    }
}
