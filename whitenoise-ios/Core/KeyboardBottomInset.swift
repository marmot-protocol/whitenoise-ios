import SwiftUI
import UIKit

private struct KeyboardAdaptiveBottomPadding: ViewModifier {
    @State private var keyboardGap: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardGap)
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { notification in
                let gap = KeyboardFrameChange.bottomGap(from: notification)
                guard KeyboardFrameChange.shouldUpdateBottomGap(current: keyboardGap, next: gap) else { return }
                withAnimation(KeyboardFrameChange.animation(from: notification)) {
                    keyboardGap = gap
                }
            }
    }
}

private struct KeyboardVisibilityTracking: ViewModifier {
    @Binding var isVisible: Bool
    var animatesChanges = true

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { notification in
                let visible = KeyboardFrameChange.isVisible(from: notification)
                guard KeyboardFrameChange.shouldUpdateVisibility(current: isVisible, next: visible) else { return }
                var transaction = Transaction(
                    animation: animatesChanges ? KeyboardFrameChange.animation(from: notification) : nil
                )
                transaction.disablesAnimations = !animatesChanges
                withTransaction(transaction) {
                    isVisible = visible
                }
            }
    }
}

private struct KeyboardAdaptiveHorizontalPadding: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .padding(
                .horizontal,
                isVisible
                    ? BottomInputChromeLayout.keyboardOpenHorizontalInset
                    : BottomInputChromeLayout.horizontalInset
            )
            .trackKeyboardVisibility($isVisible)
    }
}

extension View {
    func keyboardAdaptiveBottomPadding() -> some View {
        modifier(KeyboardAdaptiveBottomPadding())
    }

    func trackKeyboardVisibility(
        _ isVisible: Binding<Bool>,
        animatesChanges: Bool = true
    ) -> some View {
        modifier(KeyboardVisibilityTracking(isVisible: isVisible, animatesChanges: animatesChanges))
    }

    func keyboardAdaptiveHorizontalPadding(isKeyboardVisible: Binding<Bool>) -> some View {
        modifier(KeyboardAdaptiveHorizontalPadding(isVisible: isKeyboardVisible))
    }
}
