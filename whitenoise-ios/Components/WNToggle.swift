import SwiftUI

nonisolated enum WNTogglePalette {
    static let thumb = Color.white

    static func onTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(uiColor: .systemGray) : .black
    }
}

struct WNToggle<Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var isOn: Bool
    private let label: Label

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        _isOn = isOn
        self.label = label()
    }

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .tint(WNTogglePalette.onTint(for: colorScheme))
    }
}

extension WNToggle where Label == Text {
    init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(titleKey) }
    }

    init(_ title: some StringProtocol, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

#Preview("WNToggle — Light") {
    WNTogglePreview()
}

#Preview("WNToggle — Dark") {
    WNTogglePreview()
        .preferredColorScheme(.dark)
}

private struct WNTogglePreview: View {
    @State private var isOn = true
    @State private var isOff = false

    var body: some View {
        Form {
            WNToggle("Wipe Data From This Device", isOn: $isOn)
            WNToggle("Hide Screen in App Switcher", isOn: $isOff)
            WNToggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share usage and telemetry")
                    Text(verbatim: "A secondary line describing what the switch shares.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
