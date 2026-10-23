import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized, .tags(.uiHosting))
struct PrivateKeyFieldLayoutTests {
    @Test(arguments: [320.0, 402.0], [63, 512])
    func pastedKeyStaysWithinTheSignInForm(width: Double, keyLength: Int) async throws {
        // The sign-in form never reads the runtime before Continue, so a
        // hermetic state without a client is enough to lay it out.
        let controller = UIHostingController(rootView:
            NavigationStack { ImportIdentityView() }
                .environment(AppState.test())
                .frame(width: width, height: 700)
        )
        try await withHostedWindow(controller, frame: CGRect(x: 0, y: 0, width: width, height: 700)) { _ in
            controller.view.layoutIfNeeded()
            let field = try #require(secureField(in: controller.view))

            // Deliver synthetic content through UIKit without using the clipboard.
            // The item provider loads asynchronously and offers no completion.
            let key = "nsec1" + String(repeating: "q", count: keyLength - 5)
            field.paste(itemProviders: [NSItemProvider(object: key as NSString)])
            try await eventually { field.text == key }
            for focused in [false, true] {
                if focused { field.becomeFirstResponder() }
                // Focus reaches SwiftUI through the binding, whose update
                // queues the field's focus and accessory tasks on the main
                // actor: flush, let those tasks run, then lay out again.
                for _ in 0..<2 {
                    controller.view.layoutIfNeeded()
                    await Task.yield()
                }
                controller.view.layoutIfNeeded()

                let frame = field.convert(field.bounds, to: controller.view)
                #expect(frame.width > 0)
                let textWidth = field.textRect(forBounds: field.bounds).width
                #expect(textWidth <= width - 80, "Text must leave room for padding and adjacent controls")
                #expect(field.bounds.height >= 44)
                #expect(frame.minX >= 0)
                #expect(frame.maxX <= controller.view.bounds.width)
            }
        }
    }

    private func secureField(in view: UIView) -> PasteInterceptingSecureTextField? {
        if let field = view as? PasteInterceptingSecureTextField { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }
}
