import SwiftUI
import UIKit

/// Transient banner shown at the top of the screen. Used for non-fatal
/// success/failure messages that don't warrant a sheet or a full error
/// state on the current screen.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case warning
        case error
    }

    let id = UUID()
    let title: String
    let message: String?
    let style: Style
    let duration: TimeInterval

    static func success(_ title: String, message: String? = nil, duration: TimeInterval = 2.5) -> Toast {
        Toast(title: title, message: message, style: .success, duration: duration)
    }

    static func warning(_ title: String, message: String? = nil, duration: TimeInterval = 3.0) -> Toast {
        Toast(title: title, message: message, style: .warning, duration: duration)
    }

    static func error(_ title: String, message: String? = nil, duration: TimeInterval = 3.5) -> Toast {
        Toast(title: title, message: message, style: .error, duration: duration)
    }
}

enum ToastOverlayPresentation {
    static let windowLevel = UIWindow.Level.alert + 1
}

/// Top-of-screen overlay host. Attach to the root view; views below read
/// `AppState.activeToast` and call `appState.present(_:)` / `appState.dismissToast()`.
///
/// The actual banner is hosted in a dedicated pass-through window so it stays
/// above sheets, alerts, and navigation presentations instead of being trapped
/// under the root SwiftUI hierarchy.
struct ToastHost: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .onAppear {
                ToastOverlayPresenter.shared.update(toast: appState.activeToast)
            }
            .onChange(of: appState.activeToast) { _, toast in
                ToastOverlayPresenter.shared.update(toast: toast)
            }
            .onDisappear {
                ToastOverlayPresenter.shared.update(toast: nil)
            }
    }
}

@MainActor
private final class ToastOverlayPresenter {
    static let shared = ToastOverlayPresenter()

    private var window: ToastOverlayWindow?
    private var host: UIHostingController<ToastWindowContent>?

    func update(toast: Toast?) {
        guard let toast else {
            dismiss()
            return
        }

        guard let scene = activeWindowScene() else { return }

        let window = window(for: scene)
        window.layer.removeAllAnimations()
        host?.rootView = ToastWindowContent(toast: toast)

        if window.isHidden {
            window.alpha = 0
            window.isHidden = false
            UIView.animate(withDuration: 0.2) {
                window.alpha = 1
            }
        }
    }

    private func dismiss() {
        guard let window else { return }
        UIView.animate(withDuration: 0.18) {
            window.alpha = 0
        } completion: { [weak self] _ in
            guard let self else { return }
            guard self.window === window, window.alpha == 0 else { return }
            self.window?.isHidden = true
            self.window = nil
            self.host = nil
        }
    }

    private func window(for scene: UIWindowScene) -> ToastOverlayWindow {
        if let window, window.windowScene === scene {
            return window
        }
        window?.isHidden = true

        let host = UIHostingController(rootView: ToastWindowContent(toast: nil))
        host.view.backgroundColor = .clear

        let window = ToastOverlayWindow(windowScene: scene)
        window.windowLevel = ToastOverlayPresentation.windowLevel
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true

        self.host = host
        self.window = window
        return window
    }

    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
    }
}

private final class ToastOverlayWindow: UIWindow {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}

private struct ToastWindowContent: View {
    let toast: Toast?

    var body: some View {
        VStack {
            if let toast {
                ToastView(toast: toast)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: toast)
        .allowsHitTesting(false)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                if let message = toast.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }

    private var icon: String {
        switch toast.style {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

extension View {
    func toastHost() -> some View {
        modifier(ToastHost())
    }
}
