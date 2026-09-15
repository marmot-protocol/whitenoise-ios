import SwiftUI

/// Reuse the system launch storyboard so its artwork and constraints cannot
/// drift from the runtime-loading and Welcome backgrounds.
struct LaunchBrandView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        guard let controller = UIStoryboard(name: "LaunchScreen", bundle: .main)
            .instantiateInitialViewController() else {
            preconditionFailure("LaunchScreen must have an initial view controller")
        }
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
