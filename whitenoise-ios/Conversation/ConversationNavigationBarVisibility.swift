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
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
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
            navigationController?.setNavigationBarHidden(false, animated: false)
        }
    }
}
