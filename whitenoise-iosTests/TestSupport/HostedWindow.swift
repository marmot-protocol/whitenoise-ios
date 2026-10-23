import UIKit

struct HostedWindowUnavailable: Error, CustomStringConvertible {
    var description: String { "The test host has no connected UIWindowScene" }
}

/// Hosts `root` in a key window on the test host's scene for the duration of
/// `body`: sizes it (`frame`, default the scene bounds), applies `style`,
/// makes it key and visible, runs a layout pass and yields once so the first
/// SwiftUI update lands, then hides it, detaches the root and restores the
/// previous key window, also when `body` throws.
@MainActor
func withHostedWindow<T>(
    _ root: UIViewController,
    frame: CGRect? = nil,
    style: UIUserInterfaceStyle? = nil,
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
    await Task.yield()
    window.layoutIfNeeded()
    return try await body(window)
}
