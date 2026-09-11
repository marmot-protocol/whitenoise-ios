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

    private func attach(
        _ controller: InteractivePopGestureController,
        to viewController: UIViewController,
        in window: UIWindow
    ) {
        let attachment = InteractivePopGestureAttachmentView()
        attachment.controller = controller
        viewController.view.addSubview(attachment)
        window.layoutIfNeeded()
        attachment.resolveNavigationController()
    }

    @Test func attachmentViewAdoptsTheEnclosingStacksPopRecognizer() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        let controller = InteractivePopGestureController(onBegin: { 1 }, onFinish: { _, _ in })
        attach(controller, to: pushed, in: window)

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

        let controller = InteractivePopGestureController(onBegin: { 1 }, onFinish: { _, _ in })
        attach(controller, to: pushed, in: window)
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

        var begins = 0
        let controller = InteractivePopGestureController(
            onBegin: {
                begins += 1
                return begins
            },
            onFinish: { _, _ in }
        )
        attach(controller, to: root, in: window)

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(recognizer.delegate === controller)
        #expect(!controller.gestureRecognizerShouldBegin(recognizer))
        #expect(begins == 0)
    }

    @Test func beginningTheSwipeResignsTheKeyboardFirst() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        var begins = 0
        let controller = InteractivePopGestureController(
            onBegin: {
                begins += 1
                return begins
            },
            onFinish: { _, _ in }
        )
        attach(controller, to: pushed, in: window)

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(controller.gestureRecognizerShouldBegin(recognizer))
        #expect(begins == 1)
    }

    @Test func aCancelledTransitionIsReportedOnceForTheEpochItBegan() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        var outcomes: [(Int, Bool)] = []
        let controller = InteractivePopGestureController(
            onBegin: { 7 },
            onFinish: { outcomes.append(($0, $1)) }
        )
        attach(controller, to: pushed, in: window)

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(controller.gestureRecognizerShouldBegin(recognizer))

        controller.completeTransition(isCancelled: true)
        controller.completeTransition(isCancelled: true)
        controller.completeTransition(isCancelled: false)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.0 == 7)
        #expect(outcomes.first?.1 == true)
    }

    @Test func aCompletedTransitionIsReportedOnceForTheEpochItBegan() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        var outcomes: [(Int, Bool)] = []
        let controller = InteractivePopGestureController(
            onBegin: { 3 },
            onFinish: { outcomes.append(($0, $1)) }
        )
        attach(controller, to: pushed, in: window)

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(controller.gestureRecognizerShouldBegin(recognizer))

        controller.completeTransition(isCancelled: false)
        controller.completeTransition(isCancelled: true)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.0 == 3)
        #expect(outcomes.first?.1 == false)
    }

    @Test func anOutcomeWithoutAGestureIsNotReported() throws {
        let (window, _, pushed) = try makeStack()
        defer { window.isHidden = true }

        var outcomes: [(Int, Bool)] = []
        let controller = InteractivePopGestureController(
            onBegin: { 1 },
            onFinish: { outcomes.append(($0, $1)) }
        )
        attach(controller, to: pushed, in: window)

        controller.completeTransition(isCancelled: true)
        #expect(outcomes.isEmpty)
    }

    @Test func restoringDropsAnOutcomeFromTheAbandonedGesture() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        var outcomes: [(Int, Bool)] = []
        let controller = InteractivePopGestureController(
            onBegin: { 5 },
            onFinish: { outcomes.append(($0, $1)) }
        )
        attach(controller, to: pushed, in: window)

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(controller.gestureRecognizerShouldBegin(recognizer))
        controller.restore()
        controller.completeTransition(isCancelled: true)

        #expect(outcomes.isEmpty)
    }

    @Test func aSecondBeginKeepsTheEpochTheScreenIsStillHolding() throws {
        let (window, navigation, pushed) = try makeStack()
        defer { window.isHidden = true }

        var state = InteractivePopTransitionState()
        var outcomes: [(Int, Bool)] = []
        let controller = InteractivePopGestureController(
            onBegin: { state.begin(isComposerFocused: false) },
            onFinish: { outcomes.append(($0, $1)) }
        )
        attach(controller, to: pushed, in: window)

        let recognizer = try #require(navigation.interactivePopGestureRecognizer)
        #expect(controller.gestureRecognizerShouldBegin(recognizer))
        // The screen refuses the second begin, so the epoch must not move.
        #expect(controller.gestureRecognizerShouldBegin(recognizer))
        controller.completeTransition(isCancelled: true)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.0 == 1)
    }
}
