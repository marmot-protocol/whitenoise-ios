import SwiftUI
import UIKit

@MainActor
enum KeyboardFrameChange {
    enum Curve: Int, Equatable {
        case easeInOut
        case easeIn
        case easeOut
        case linear

        func animation(duration: TimeInterval) -> Animation {
            switch self {
            case .easeInOut:
                .easeInOut(duration: duration)
            case .easeIn:
                .easeIn(duration: duration)
            case .easeOut:
                .easeOut(duration: duration)
            case .linear:
                .linear(duration: duration)
            }
        }
    }

    struct AnimationParameters: Equatable {
        let duration: TimeInterval
        let curve: Curve

        var animation: Animation {
            curve.animation(duration: duration)
        }
    }

    static func isVisible(from notification: Notification) -> Bool {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let screenBounds
        else { return false }

        return frame.minY < screenBounds.maxY && frame.maxY > screenBounds.minY
    }

    static func bottomGap(from notification: Notification) -> CGFloat {
        isVisible(from: notification) ? BottomInputChromeLayout.keyboardInset : 0
    }

    static func shouldUpdateBottomGap(current: CGFloat, next: CGFloat) -> Bool {
        abs(current - next) > 0.5
    }

    static func shouldUpdateVisibility(current: Bool, next: Bool) -> Bool {
        current != next
    }

    static func animation(from notification: Notification) -> Animation {
        animationParameters(from: notification).animation
    }

    static func animationParameters(from notification: Notification) -> AnimationParameters {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        let rawCurve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
        return animationParameters(duration: duration, rawCurve: rawCurve)
    }

    static func animationParameters(
        duration: TimeInterval?,
        rawCurve: Int?
    ) -> AnimationParameters {
        AnimationParameters(
            duration: duration ?? 0.25,
            curve: rawCurve.flatMap(Curve.init(rawValue:)) ?? .easeInOut
        )
    }

    private static var screenBounds: CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.screen.bounds
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })?.screen.bounds
            ?? scenes.first?.screen.bounds
    }
}
