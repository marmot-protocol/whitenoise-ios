import Testing
import UIKit
@testable import whitenoise_ios

struct ComposerReturnKeyBehaviorTests {
    private func action(
        sendsOnReturn: Bool = true,
        _ replacement: String,
        hasMarkedText: Bool = false,
        isPaste: Bool = false
    ) -> ComposerReturnKeyBehavior.Action {
        ComposerReturnKeyBehavior.action(
            sendsOnReturn: sendsOnReturn,
            replacementText: replacement,
            hasMarkedText: hasMarkedText,
            isPaste: isPaste
        )
    }

    @Test func returnInsertsNewlineByDefault() {
        #expect(action(sendsOnReturn: false, "\n") == .insert)
        #expect(ComposerReturnKeyBehavior.returnKeyType(sendsOnReturn: false) == .default)
    }

    @Test func loneReturnSendsWhenEnabled() {
        #expect(action("\n") == .send)
        #expect(ComposerReturnKeyBehavior.returnKeyType(sendsOnReturn: true) == .send)
    }

    @Test(arguments: ["first\nsecond", "\n\n", "line\n", "\nline", "a", "", "\r\n"])
    func multiCharacterOrTypedTextNeverSends(replacement: String) {
        #expect(action(replacement) == .insert)
    }

    @Test(arguments: ["\n", "first\nsecond", "\n\n"])
    func pasteNeverSends(replacement: String) {
        #expect(action(replacement, isPaste: true) == .insert)
    }

    @Test func returnCommittingMarkedTextDoesNotSend() {
        #expect(action("\n", hasMarkedText: true) == .insert)
    }
}
