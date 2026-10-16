import SwiftUI
import UIKit

/// Observes completed native appearances so the support handoff does not rely
/// on animation-duration guesses or recreate an already-pushed conversation.
struct SupportChatTransitionObserver: UIViewControllerRepresentable {
    var controller: Controller?
    let onAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = controller ?? Controller()
        controller.onAppear = onAppear
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onAppear = onAppear
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.onAppear = {}
    }

    final class Controller: UIViewController {
        var onAppear: () -> Void = {}
        private weak var observedNavigationController: UINavigationController?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            observedNavigationController = navigationController
            Task { @MainActor [weak self] in self?.onAppear() }
        }

        func snapshot() -> UIImage? {
            guard let source = observedNavigationController?.view,
                  source.window != nil, !source.bounds.isEmpty else { return nil }
            return UIGraphicsImageRenderer(bounds: source.bounds).image { _ in
                source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
            }
        }
    }
}
