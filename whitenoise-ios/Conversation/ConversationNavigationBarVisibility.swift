import SwiftUI
import UIKit

/// Apply the conversation's hidden bar before UIKit starts its push transition.
/// Restore the native bar when leaving for Chats or contact/group details.
struct ConversationNavigationBarVisibility: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var isConversationVisible = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isConversationVisible = true
            guard let navigationController else { return }
            UIView.performWithoutAnimation {
                // SwiftUI may already have requested an animated hide. Reapply it
                // synchronously so the outgoing controls cannot cover our header.
                navigationController.setNavigationBarHidden(false, animated: false)
                navigationController.setNavigationBarHidden(true, animated: false)
                navigationController.view.layoutIfNeeded()
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigationController, !navigationController.isNavigationBarHidden else { return }
            navigationController.setNavigationBarHidden(true, animated: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isConversationVisible = false
            guard let navigationController else { return }
            // A conversation that replaced this one may have appeared first.
            if let top = navigationController.topViewController, Self.showsConversation(top) { return }
            navigationController.setNavigationBarHidden(false, animated: false)
        }

        private static func showsConversation(_ controller: UIViewController) -> Bool {
            (controller as? Controller)?.isConversationVisible == true
                || controller.children.contains(where: showsConversation)
        }
    }
}
