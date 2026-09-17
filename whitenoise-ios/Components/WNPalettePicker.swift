import SwiftUI

/// The Share/Connect switch: a palette picker in the app's monochrome accent.
/// The container shape is left to the platform — iOS 26 draws a capsule, and
/// earlier releases draw a soft-cornered rectangle whose selected segment is
/// rectangular too, so imposing a capsule there only mismatches the two.
private struct WNPalettePicker: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelsHidden()
            .pickerStyle(.palette)
            .controlSize(.extraLarge)
            .wnNeutralAccentTint()
    }
}

extension View {
    func wnPalettePicker() -> some View {
        modifier(WNPalettePicker())
    }
}

#Preview("WNPalettePicker") {
    WNPalettePickerPreview()
}

private struct WNPalettePickerPreview: View {
    @State private var selection = 0

    var body: some View {
        Picker("Mode", selection: $selection) {
            Text("Share").tag(0)
            Text("Connect").tag(1)
        }
        .wnPalettePicker()
        .frame(width: 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
