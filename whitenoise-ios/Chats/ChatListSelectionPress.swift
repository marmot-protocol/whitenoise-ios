import SwiftUI

struct ChatListSelectionPress: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onLongPressGesture {
                guard isEnabled else { return }
                action()
            }
    }
}
