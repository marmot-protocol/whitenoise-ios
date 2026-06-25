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
                withAnimation(KeyboardFrameChange.animation(from: notification)) {
                    keyboardGap = gap
                }
            }
    }
}

private struct KeyboardVisibilityTracking: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { notification in
                let visible = KeyboardFrameChange.isVisible(from: notification)
                withAnimation(KeyboardFrameChange.animation(from: notification)) {
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

    func trackKeyboardVisibility(_ isVisible: Binding<Bool>) -> some View {
        modifier(KeyboardVisibilityTracking(isVisible: isVisible))
    }

    func keyboardAdaptiveHorizontalPadding(isKeyboardVisible: Binding<Bool>) -> some View {
        modifier(KeyboardAdaptiveHorizontalPadding(isVisible: isKeyboardVisible))
    }
}
