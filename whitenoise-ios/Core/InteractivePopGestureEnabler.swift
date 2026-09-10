import SwiftUI
import UIKit

/// Restores the screen-edge back swipe on a pushed screen that hides the
/// navigation bar. UIKit disables `interactivePopGestureRecognizer` when there
/// is no bar back button for it to mirror, so the recognizer is re-enabled and
/// given a delegate that applies `InteractivePopGesturePolicy`.
struct InteractivePopGestureEnabler: UIViewRepresentable {
    /// Called as the swipe starts. Returns the navigation epoch the pop is
    /// bound to, or nil when a pop is already in flight.
    var onBegin: () -> Int? = { nil }
    /// Reports the pop's terminal outcome for the epoch `onBegin` handed out,
    /// so the screen can restore only what a cancelled pop took away.
    var onFinish: (Int, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> InteractivePopGestureController {
        InteractivePopGestureController(onBegin: onBegin, onFinish: onFinish)
    }

    func makeUIView(context: Context) -> InteractivePopGestureAttachmentView {
        let view = InteractivePopGestureAttachmentView()
        view.isUserInteractionEnabled = false
        view.controller = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InteractivePopGestureAttachmentView, context: Context) {
        context.coordinator.onBegin = onBegin
        context.coordinator.onFinish = onFinish
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
    var onBegin: () -> Int?
    var onFinish: (Int, Bool) -> Void

    private weak var navigationController: UINavigationController?
    private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
    private weak var trackedRecognizer: UIGestureRecognizer?
    private var activeEpoch: Int?
    /// Set between `shouldBegin` and the moment a transition coordinator
    /// appears. A gesture that ends while still awaiting one never handed off
    /// to a pop, so it resolves as cancelled.
    private var isAwaitingTransition = false

    init(onBegin: @escaping () -> Int?, onFinish: @escaping (Int, Bool) -> Void) {
        self.onBegin = onBegin
        self.onFinish = onFinish
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
        if trackedRecognizer !== recognizer {
            trackedRecognizer?.removeTarget(self, action: nil)
            recognizer.addTarget(self, action: #selector(popGestureDidChange))
            trackedRecognizer = recognizer
        }
        // A bar-visibility change can re-disable the recognizer under us.
        recognizer.isEnabled = true
    }

    func restore() {
        if let trackedRecognizer {
            if trackedRecognizer.delegate === self {
                trackedRecognizer.delegate = originalDelegate
            }
            trackedRecognizer.removeTarget(self, action: nil)
        }
        trackedRecognizer = nil
        navigationController = nil
        originalDelegate = nil
        activeEpoch = nil
        isAwaitingTransition = false
    }

    func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
        guard let navigationController else { return false }
        let shouldBegin = InteractivePopGesturePolicy.shouldBegin(
            stackDepth: navigationController.viewControllers.count,
            isTransitioning: navigationController.transitionCoordinator != nil
        )
        guard shouldBegin else { return false }
        if let epoch = onBegin() {
            activeEpoch = epoch
        }
        isAwaitingTransition = true
        return true
    }

    /// The transition coordinator's terminal report. UIKit drives this through
    /// `notifyWhenInteractionChanges`; it resolves at most once per epoch.
    func completeTransition(isCancelled: Bool) {
        isAwaitingTransition = false
        guard let epoch = activeEpoch else { return }
        activeEpoch = nil
        onFinish(epoch, isCancelled)
    }

    @objc private func popGestureDidChange(_ recognizer: UIGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            observeTransitionCoordinator()
        case .ended, .cancelled, .failed:
            observeTransitionCoordinator()
            if isAwaitingTransition {
                completeTransition(isCancelled: true)
            }
        default:
            break
        }
    }

    private func observeTransitionCoordinator() {
        guard isAwaitingTransition,
              let coordinator = navigationController?.transitionCoordinator
        else { return }
        isAwaitingTransition = false
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            let isCancelled = context.isCancelled
            MainActor.assumeIsolated {
                self?.completeTransition(isCancelled: isCancelled)
            }
        }
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
}

extension UIView {
    /// Walks the responder chain rather than the view tree: a SwiftUI-hosted
    /// view has no `UIViewController` ancestor of its own to ask.
    func enclosingNavigationController() -> UINavigationController? {
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
