import UIKit

nonisolated enum ComposerReturnKeyBehavior {
    enum Action: Equatable {
        case insert
        case send
    }

    static let storageKey = "composer.returnKeySends"

    static func action(
        sendsOnReturn: Bool,
        replacementText: String,
        hasMarkedText: Bool,
        isPaste: Bool
    ) -> Action {
        guard sendsOnReturn, !isPaste, !hasMarkedText, replacementText == "\n" else { return .insert }
        return .send
    }

    static func returnKeyType(sendsOnReturn: Bool) -> UIReturnKeyType {
        sendsOnReturn ? .send : .default
    }
}
