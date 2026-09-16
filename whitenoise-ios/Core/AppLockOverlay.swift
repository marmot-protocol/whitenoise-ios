import SwiftUI
import UIKit

/// Hosts the lock/cover shield in its own window above the key window's
/// presentation stack. A SwiftUI overlay on the root view can't do this:
/// sheets and full-screen covers present in a layer above the root view, so
/// their content would still be visible in the app switcher.
@MainActor
final class AppLockOverlayPresenter {
    private var window: UIWindow?

    func update(
        for shield: AppLockController.Shield,
        controller: AppLockController,
        appearance: AppAppearanceStore
    ) {
        guard shield != .hidden else {
            window?.isHidden = true
            return
        }
        guard let window = window ?? makeWindow(
            controller: controller,
            appearance: appearance
        ) else { return }
        window.isHidden = false
    }

    private func makeWindow(
        controller: AppLockController,
        appearance: AppAppearanceStore
    ) -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let scene else { return nil }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = AppearanceTheme.resolved(
            rawValue: UserDefaults.standard.string(forKey: AppearanceTheme.storageKey)
        ).userInterfaceStyle
        let host = UIHostingController(
            rootView: AppLockShieldView()
                .environment(controller)
                .environment(appearance)
                .appAppearance(appearance)
        )
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        self.window = window
        return window
    }
}

/// Splash-style opaque cover; adds the unlock affordance when locked.
struct AppLockShieldView: View {
    @Environment(AppLockController.self) private var appLock

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            Image("WnLogo")
                .accessibilityHidden(true)
            if appLock.shield == .locked {
                VStack {
                    Spacer()
                    Text("White Noise is locked")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    WNButton(title: "Unlock", size: .compact) {
                        Task { await appLock.requestUnlock() }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 48)
                }
                .opacity(appLock.isAuthenticating ? 0 : 1)
                .animation(.default, value: appLock.isAuthenticating)
            }
        }
    }
}
