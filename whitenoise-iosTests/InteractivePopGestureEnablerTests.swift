import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct InteractivePopGestureEnablerTests {
    private func makeStack() throws -> (UIWindow, UINavigationController, UIViewController) {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let pushed = UIViewController()
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(pushed, animated: false)
        navigation.setNavigationBarHidden(true, animated: false)

        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, navigation, pushed)
    }

    @Test func attachmentViewAdoptsTheEnclosingStacksPopRecognizer() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        let controller = InteractivePopGestureController(onBegin: {})
        let attachment = InteractivePopGestureAttachmentView()
        attachment.controller = controller
        pushed.view.addSubview(attachment)
        window.layoutIfNeeded()
        attachment.resolveNavigationController()

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(recognizer.delegate === controller)
        #expect(recognizer.isEnabled)
        #expect(controller.gestureRecognizerShouldBegin(recognizer))
    }

    @Test func restoreHandsTheRecognizerBackToUIKit() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        let systemDelegate = recognizer.delegate

        let controller = InteractivePopGestureController(onBegin: {})
        let attachment = InteractivePopGestureAttachmentView()
        attachment.controller = controller
        pushed.view.addSubview(attachment)
        window.layoutIfNeeded()
        attachment.resolveNavigationController()
        #expect(recognizer.delegate === controller)

        controller.restore()
        #expect(recognizer.delegate === systemDelegate)
    }

    @Test func swipeAtTheRootIsRefusedAndResignsNothing() throws {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.setNavigationBarHidden(true, animated: false)
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        var didBegin = false
        let controller = InteractivePopGestureController(onBegin: { didBegin = true })
        let attachment = InteractivePopGestureAttachmentView()
        attachment.controller = controller
        root.view.addSubview(attachment)
        window.layoutIfNeeded()
        attachment.resolveNavigationController()

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(recognizer.delegate === controller)
        #expect(!controller.gestureRecognizerShouldBegin(recognizer))
        #expect(!didBegin)
    }

    @Test func beginningTheSwipeResignsTheKeyboardFirst() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        var didBegin = false
        let controller = InteractivePopGestureController(onBegin: { didBegin = true })
        let attachment = InteractivePopGestureAttachmentView()
        attachment.controller = controller
        pushed.view.addSubview(attachment)
        window.layoutIfNeeded()
        attachment.resolveNavigationController()

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(controller.gestureRecognizerShouldBegin(recognizer))
        #expect(didBegin)
    }
}
