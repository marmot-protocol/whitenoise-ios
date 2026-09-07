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

        // Exercise the same editing-change path as paste without using the clipboard.
        field.text = "nsec1" + String(repeating: "q", count: keyLength - 5)
        field.sendActions(for: .editingChanged)
        for focused in [false, true] {
            if focused { field.becomeFirstResponder() }
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(10))
                controller.view.layoutIfNeeded()
            }

            let frame = field.convert(field.bounds, to: controller.view)
            #expect(frame.width > 0)
            #expect(frame.width <= width - 80, "Secure field must leave room for padding and adjacent controls: \(frame)")
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= controller.view.bounds.width)
        }

    }

    private func secureField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.isSecureTextEntry { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }
}
