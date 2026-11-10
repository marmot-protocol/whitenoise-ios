import SwiftUI

/// Reuse the system launch storyboard so its artwork and constraints cannot
/// drift from the runtime-loading, Welcome, and privacy-cover backgrounds.
struct LaunchBrandView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = Self.makeViewController()
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    static func makeViewController() -> UIViewController {
        guard let controller = UIStoryboard(name: "LaunchScreen", bundle: .main)
            .instantiateInitialViewController() else {
            preconditionFailure("LaunchScreen must have an initial view controller")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
