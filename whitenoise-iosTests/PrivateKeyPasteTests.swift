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
        let pastedText = "several words separated by spaces"
        let providers = [NSItemProvider(object: pastedText as NSString)]
        #expect(field.canPaste(providers))
        target.paste?(itemProviders: providers)
        for _ in 0..<100 where reportedText == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(field.text == pastedText)
        #expect(reportedText == pastedText)
        #expect(hadPasteToken)
    }

    @Test func visibilityTogglePreservesTextSelectionAndFurtherTyping() throws {
        let (field, window) = try makeVisibleField(notificationCenter: NotificationCenter())
        defer { window.isHidden = true }
        field.text = "synthetic-key"
        field.updateAccessory(visible: true)
        field.becomeFirstResponder()
        let caret = try #require(field.position(from: field.beginningOfDocument, offset: 3))
        field.selectedTextRange = field.textRange(from: caret, to: caret)
        let button = try #require(field.rightView as? UIButton)

        button.sendActions(for: .touchUpInside)
        #expect(!field.isSecureTextEntry)
        #expect(field.text == "synthetic-key")
        #expect(field.isFirstResponder)
        let selection = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.start) == 3)
        field.insertText("X")
        #expect(field.text == "synXthetic-key")

        button.sendActions(for: .touchUpInside)
        #expect(field.isSecureTextEntry)
        field.insertText("Y")
        #expect(field.text == "synXYthetic-key")
    }

    @Test func revealedKeyIsHiddenOnInactivityEmptyingAndDismissal() throws {
        let notifications = NotificationCenter()
        let (field, window) = try makeVisibleField(notificationCenter: notifications)
        defer { window.isHidden = true }
        #expect(field.isSecureTextEntry)
        #expect(field.rightView is UIPasteControl)
        field.text = "synthetic-key"
        field.updateAccessory(visible: true)
        let button = try #require(field.rightView as? UIButton)
        button.sendActions(for: .touchUpInside)
        #expect(!field.isSecureTextEntry)

        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(field.isSecureTextEntry)
        #expect(field.text == "synthetic-key")

        button.sendActions(for: .touchUpInside)
        field.text = ""
        field.updateAccessory(visible: true)
        #expect(field.isSecureTextEntry)
        #expect(field.rightView is UIPasteControl)

        field.text = "another-key"
        field.updateAccessory(visible: true)
        #expect(field.isSecureTextEntry)
        button.sendActions(for: .touchUpInside)
        field.removeFromSuperview()
        #expect(field.isSecureTextEntry)
        #expect(field.text == "another-key")
    }

    private func makeVisibleField(notificationCenter: NotificationCenter) throws -> (PasteInterceptingSecureTextField, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let field = PasteInterceptingSecureTextField()
        field.configureAccessory(notificationCenter: notificationCenter)
        controller.view.addSubview(field)
        field.frame = CGRect(x: 20, y: 100, width: 280, height: 50)
        window.makeKeyAndVisible()
        return (field, window)
    }
}
