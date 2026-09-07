import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct PrivateKeyFieldLayoutTests {
    @Test(arguments: [320.0, 402.0], [63, 512])
    func pastedKeyStaysWithinTheSignInForm(width: Double, keyLength: Int) async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let controller = UIHostingController(rootView:
            NavigationStack { ImportIdentityView(showsCloseButton: true) }
                .environment(appState)
                .frame(width: width, height: 700)
        )
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let field = try #require(secureField(in: controller.view))

        // Deliver synthetic content through UIKit without using the clipboard.
        let key = "nsec1" + String(repeating: "q", count: keyLength - 5)
        field.paste(itemProviders: [NSItemProvider(object: key as NSString)])
        for _ in 0..<100 where field.text != key {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(field.text == key)
        for focused in [false, true] {
            if focused { field.becomeFirstResponder() }
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(10))
                controller.view.layoutIfNeeded()
            }

            let frame = field.convert(field.bounds, to: controller.view)
            #expect(frame.width > 0)
            let textWidth = field.textRect(forBounds: field.bounds).width
            #expect(textWidth <= width - 80, "Text must leave room for padding and adjacent controls")
            #expect(field.bounds.height >= 44)
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= controller.view.bounds.width)
        }

    }

    private func secureField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.isSecureTextEntry { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }
}
