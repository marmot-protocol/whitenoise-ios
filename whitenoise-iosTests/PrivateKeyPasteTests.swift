import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct PrivateKeyPasteTests {
    @Test(arguments: [false, true])
    func itemProviderPasteReportsTheInsertedText(alreadyFocused: Bool) async throws {
        let field = PasteInterceptingSecureTextField()
        field.isSecureTextEntry = true
        field.pasteDelegate = field
        field.configureAccessory()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(field)
        field.frame = CGRect(x: 20, y: 100, width: 280, height: 50)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        if alreadyFocused { field.becomeFirstResponder() }

        var reportedText: String?
        var hadPasteToken = false
        field.onPaste = { token, text in
            reportedText = text
            hadPasteToken = token != nil
        }
        // Exercise UIKit's native paste delivery without reading or replacing the clipboard.
        let control = try #require(field.rightView as? UIPasteControl)
        let target = try #require(control.target)
        target.paste?(itemProviders: [NSItemProvider(object: "synthetic-key" as NSString)])
        for _ in 0..<100 where reportedText == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(field.text == "synthetic-key")
        #expect(reportedText == "synthetic-key")
        #expect(hadPasteToken)
    }
}
