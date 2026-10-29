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
        private var isBeingRemoved = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            isBeingRemoved = parent == nil
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

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isConversationVisible = false
            guard let navigationController else { return }
            guard isBeingRemoved else {
                navigationController.setNavigationBarHidden(false, animated: false)
                return
            }
            // Rebuilt in place: its replacement may already be showing the conversation.
            Task { @MainActor [weak navigationController] in
                guard let navigationController,
                      let top = navigationController.topViewController,
                      !Self.showsConversation(top)
                else { return }
                navigationController.setNavigationBarHidden(false, animated: false)
            }
        }

        private static func showsConversation(_ controller: UIViewController) -> Bool {
            (controller as? Controller)?.isConversationVisible == true
                || controller.children.contains(where: showsConversation)
        }
    }
}
