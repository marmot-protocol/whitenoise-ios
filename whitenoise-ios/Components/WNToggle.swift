import SwiftUI

private struct WNNeutralToggleTint: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(colorScheme == .dark ? Color(uiColor: .systemGray) : .black)
    }
}

extension View {
    func wnNeutralToggleTint() -> some View {
        modifier(WNNeutralToggleTint())
    }
}

#Preview("WNNeutralToggleTint") {
    @Previewable @State var isOn = true

    return Form {
        Toggle("Wipe Data From This Device", isOn: $isOn)
            .wnNeutralToggleTint()
    }
}
