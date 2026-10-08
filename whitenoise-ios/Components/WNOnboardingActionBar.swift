import SwiftUI

/// Only pinned actions need a scroll-edge backdrop; form actions scroll with their content.
struct WNOnboardingActionBar<Actions: View>: ViewModifier {
    var isPresented = true
    @ViewBuilder var actions: () -> Actions

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollEdgeEffectHidden(!isPresented, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    if isPresented { actions() }
                }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isPresented { actions().background(.bar) }
            }
        }
    }
}
