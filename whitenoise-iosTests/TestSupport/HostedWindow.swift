import UIKit

struct HostedWindowUnavailable: Error, CustomStringConvertible {
    var description: String { "The test host has no connected UIWindowScene" }
}

/// Hosts `root` in a key window on the test host's scene for the duration of
/// `body`: sizes it (`frame`, default the scene bounds), applies `style`,
/// makes it key and visible and runs a layout pass. By default it then yields
/// once and lays out again so the first SwiftUI update lands before `body`;
/// pass `awaitingFirstUpdate: false` to run `body` right after the first
/// layout pass instead (to capture state before any update). Afterwards it
/// hides the window, detaches the root and restores the previous key window,
/// also when `body` throws.
@MainActor
func withHostedWindow<T>(
    _ root: UIViewController,
    frame: CGRect? = nil,
    style: UIUserInterfaceStyle? = nil,
    awaitingFirstUpdate: Bool = true,
    _ body: (UIWindow) async throws -> T
) async throws -> T {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
        throw HostedWindowUnavailable()
    }
    let previousKeyWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    window.frame = frame ?? scene.coordinateSpace.bounds
    if let style { window.overrideUserInterfaceStyle = style }
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
    window.layoutIfNeeded()
    if awaitingFirstUpdate {
        await Task.yield()
        window.layoutIfNeeded()
    }
    return try await body(window)
}
