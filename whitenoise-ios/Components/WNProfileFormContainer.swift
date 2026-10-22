import SwiftUI

/// Keeps native profile fields visible as focus, multiline content and keyboard geometry change.
struct WNProfileFormContainer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isKeyboardVisible = false

    let focusedField: WNProfileField?
    let nameFieldHeight: CGFloat
    let aboutFieldHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .formStyle(.grouped)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .safeAreaPadding(.bottom, isKeyboardVisible ? BottomInputChromeLayout.keyboardInset : 0)
                // Native keyboard avoidance owns the motion; animating Form updates also morphs its rows.
                .trackKeyboardVisibility($isKeyboardVisible, animatesChanges: false)
                .onChange(of: focusedField) { revealFocusedField(using: proxy) }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    revealFocusedField(using: proxy)
                }
                .onScrollGeometryChange(for: CGSize.self) { $0.visibleRect.size } action: { oldSize, newSize in
                    if newSize.height < oldSize.height || newSize.width != oldSize.width {
                        revealFocusedField(using: proxy)
                    }
                }
                .onChange(of: nameFieldHeight) {
                    if focusedField == .name { revealFocusedField(using: proxy) }
                }
                .onChange(of: aboutFieldHeight) {
                    if focusedField == .about { revealFocusedField(using: proxy) }
                }
        }
    }

    private func revealFocusedField(using proxy: ScrollViewProxy) {
        guard let focusedField else { return }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(focusedField)
        }
    }
}
