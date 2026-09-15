import SwiftUI
import UIKit

nonisolated enum ScreenPrivacyPolicy {
    static func shouldCover(enabled: Bool, sceneIsActive: Bool, isCaptured: Bool) -> Bool {
        enabled && (!sceneIsActive || isCaptured)
    }
}

/// A separate, non-key window covers sheets as well as the root content.
@MainActor
final class WindowCaptureProtection {
    private(set) var shieldWindow: UIWindow?
    private weak var protectedWindow: UIWindow?

    var isActive: Bool { shieldWindow?.isHidden == false }

    func update(enabled: Bool, window: UIWindow?, sceneIsActive: Bool, isCaptured: Bool) {
        guard enabled, let window, let scene = window.windowScene else {
            removeShield()
            return
        }
        if protectedWindow !== window {
            removeShield()
            protectedWindow = window
        }
        let shouldCover = ScreenPrivacyPolicy.shouldCover(
            enabled: enabled, sceneIsActive: sceneIsActive, isCaptured: isCaptured
        )
        if shouldCover, shieldWindow == nil {
            let shield = UIWindow(windowScene: scene)
            shield.windowLevel = .alert + 2
            let host = UIViewController()
            host.view.backgroundColor = .systemBackground
            host.view.accessibilityViewIsModal = true
            let logo = UIImageView(image: UIImage(named: "WnLogo"))
            logo.translatesAutoresizingMaskIntoConstraints = false
            logo.contentMode = .scaleAspectFit
            host.view.addSubview(logo)
            NSLayoutConstraint.activate([
                logo.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
                logo.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
                logo.widthAnchor.constraint(lessThanOrEqualTo: host.view.widthAnchor, multiplier: 0.5),
                logo.heightAnchor.constraint(lessThanOrEqualTo: host.view.heightAnchor, multiplier: 0.5)
            ])
            shield.rootViewController = host
            shieldWindow = shield
        }
        shieldWindow?.overrideUserInterfaceStyle = window.traitCollection.userInterfaceStyle
        shieldWindow?.isHidden = !shouldCover
    }

    func removeShield() {
        shieldWindow?.isHidden = true
        shieldWindow = nil
        protectedWindow = nil
    }
}

/// Observes the actual hosting scene rather than guessing from connected scenes.
struct ScreenPrivacyProtection: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> ScreenPrivacyObserverView {
        ScreenPrivacyObserverView()
    }

    func updateUIView(_ view: ScreenPrivacyObserverView, context: Context) {
        view.isEnabled = isEnabled
        view.refresh()
    }

    static func dismantleUIView(_ view: ScreenPrivacyObserverView, coordinator: ()) {
        view.isEnabled = false
        view.protection.removeShield()
    }
}

final class ScreenPrivacyObserverView: UIView {
    let protection = WindowCaptureProtection()
    var isEnabled = false
    private var sceneIsActive: Bool?

    init(notificationCenter: NotificationCenter = .default) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitSceneCaptureState.self, UITraitUserInterfaceStyle.self]) {
            (view: ScreenPrivacyObserverView, _: UITraitCollection) in
            view.refresh()
        }
        let center = notificationCenter
        center.addObserver(self, selector: #selector(sceneWillDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidDisconnect), name: UIScene.didDisconnectNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneIsActive = window?.windowScene?.activationState == .foregroundActive
        refresh()
    }

    func refresh(sceneIsActive: Bool? = nil) {
        if let sceneIsActive { self.sceneIsActive = sceneIsActive }
        protection.update(
            enabled: isEnabled,
            window: window,
            sceneIsActive: self.sceneIsActive ?? (window?.windowScene?.activationState == .foregroundActive),
            isCaptured: traitCollection.sceneCaptureState == .active
        )
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard notification.object as? UIWindowScene === window?.windowScene else { return }
        // Cover synchronously before UIKit takes the app-switcher snapshot.
        refresh(sceneIsActive: false)
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        sceneWillDeactivate(notification)
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard notification.object as? UIWindowScene === window?.windowScene else { return }
        refresh(sceneIsActive: true)
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard notification.object as? UIWindowScene === window?.windowScene else { return }
        protection.removeShield()
    }
}
