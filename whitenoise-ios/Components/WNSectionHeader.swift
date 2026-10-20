import SwiftUI

/// Grouped `Form` section headers are not stable across the versions this app
/// supports: iOS 18 draws them uppercase at a light weight, iOS 26 draws them
/// mixed case and semibold. Pinning the iOS 26 appearance keeps one design on
/// both.
nonisolated enum WNSectionHeaderMetrics {
    static var font: Font { .subheadline.weight(.semibold) }
}

private struct WNSectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textCase(nil)
            .font(WNSectionHeaderMetrics.font)
            .foregroundStyle(.secondary)
    }
}

extension View {
    func wnSectionHeader() -> some View {
        modifier(WNSectionHeaderStyle())
    }
}

#Preview("WNSectionHeader") {
    Form {
        Section {
            Text("Marmota")
        } header: {
            Text("Name").wnSectionHeader()
        }

        Section {
            Text("marmota@whitenoise.example")
        } header: {
            Text("Verified Nostr Address").wnSectionHeader()
        }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(.background)
}
