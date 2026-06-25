import SwiftUI

extension View {
    /// Pins bottom input chrome like iMessage: `safeAreaBar` on iOS 26, inset fallback earlier.
    @ViewBuilder
    func bottomInputChromeAccessory<Accessory: View>(
        @ViewBuilder accessory: @escaping () -> Accessory
    ) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0) {
                accessory()
            }
            .toolbarBackgroundVisibility(.hidden, for: .bottomBar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                accessory()
            }
        }
    }
}
