import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct ComposerTextInputLayoutTests {
    private struct Harness: View {
        @State private var text = ""
        @State private var focused = false
        var body: some View {
            ComposerTextInput(text: $text, isFocused: $focused, fontSize: 18, focusRequest: 0, onPasteImage: { _ in })
                .frame(width: 240)
        }
    }

    private func input(in view: UIView) -> ImagePasteTextView? {
        if let input = view as? ImagePasteTextView { return input }
        return view.subviews.lazy.compactMap { input(in: $0) }.first
    }

    @Test func hostedComposerScrollsToCaretAfterGrowingPastHeightLimit() async throws {
        let controller = UIHostingController(rootView: Harness())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let textView = try #require(input(in: controller.view))
        for index in 1...10 {
            textView.insertText("Line \(index)\n")
            await Task.yield()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            textView.layoutIfNeeded()
        }
        #expect(textView.bounds.height <= 112)
        #expect(textView.isScrollEnabled)
        #expect(textView.contentSize.height > textView.bounds.height)
        let caret = textView.caretRect(for: textView.endOfDocument)
        #expect(caret.maxY <= textView.bounds.maxY + 1)
        #expect(textView.contentOffset.y > 0)
        // Scrolling through older draft text must not snap back on a layout pass.
        textView.setContentOffset(.zero, animated: false)
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        #expect(textView.contentOffset.y == 0)
        #expect(textView.isScrollEnabled)

        // Moving the insertion point requests a reveal without rewriting the draft.
        let original = textView.text
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.delegate?.textViewDidChangeSelection?(textView)
        textView.layoutIfNeeded()
        #expect(textView.contentOffset.y > 0)
        #expect(textView.text == original)

        textView.selectedRange = NSRange(location: 0, length: (textView.text as NSString).length)
        textView.insertText("Short again")
        await Task.yield()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        #expect(!textView.isScrollEnabled)
        #expect(textView.bounds.height < 112)
        #expect(textView.contentOffset.y == 0)
    }
}
