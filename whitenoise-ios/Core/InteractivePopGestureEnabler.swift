import SwiftUI
import UIKit

/// Restores the screen-edge back swipe on a pushed screen that hides the
/// navigation bar. UIKit disables `interactivePopGestureRecognizer` when there
/// is no bar back button for it to mirror, so the recognizer is re-enabled and
/// given a delegate that applies `InteractivePopGesturePolicy`.
struct InteractivePopGestureEnabler: UIViewRepresentable {
    /// Called as the swipe starts, so the screen can resign the keyboard before
    /// the pop animation rather than mid-transition.
    var onBegin: () -> Void = {}

    func makeCoordinator() -> InteractivePopGestureController {
        InteractivePopGestureController(onBegin: onBegin)
    }

    func makeUIView(context: Context) -> InteractivePopGestureAttachmentView {
        let view = InteractivePopGestureAttachmentView()
        view.isUserInteractionEnabled = false
        view.controller = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InteractivePopGestureAttachmentView, context: Context) {
        context.coordinator.onBegin = onBegin
        uiView.controller = context.coordinator
        uiView.resolveNavigationController()
    }

    static func dismantleUIView(
        _ uiView: InteractivePopGestureAttachmentView,
        coordinator: InteractivePopGestureController
    ) {
        uiView.controller = nil
        coordinator.restore()
    }
}

@MainActor
final class InteractivePopGestureController: NSObject, UIGestureRecognizerDelegate {
    var onBegin: () -> Void
    private weak var navigationController: UINavigationController?
    private weak var originalDelegate: (any UIGestureRecognizerDelegate)?

    init(onBegin: @escaping () -> Void) {
        self.onBegin = onBegin
    }

    func adopt(_ controller: UINavigationController?) {
        guard let controller,
              let recognizer = controller.interactivePopGestureRecognizer
        else { return }
        if recognizer.delegate !== self {
            navigationController = controller
            originalDelegate = recognizer.delegate
            recognizer.delegate = self
        }
        // A bar-visibility change can re-disable the recognizer under us.
        recognizer.isEnabled = true
    }

    func restore() {
        let recognizer = navigationController?.interactivePopGestureRecognizer
        if recognizer?.delegate === self {
            recognizer?.delegate = originalDelegate
        }
        navigationController = nil
        originalDelegate = nil
    }

    func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
        guard let navigationController else { return false }
        let shouldBegin = InteractivePopGesturePolicy.shouldBegin(
            stackDepth: navigationController.viewControllers.count,
            isTransitioning: navigationController.transitionCoordinator != nil
        )
        if shouldBegin { onBegin() }
        return shouldBegin
    }
}

final class InteractivePopGestureAttachmentView: UIView {
    weak var controller: InteractivePopGestureController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveNavigationController()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveNavigationController()
    }

    func resolveNavigationController() {
        guard window != nil else { return }
        controller?.adopt(enclosingNavigationController())
    }

    private func enclosingNavigationController() -> UINavigationController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let navigationController = (current as? UIViewController)?.navigationController {
                return navigationController
            }
            responder = current.next
        }
        return nil
    }
}
