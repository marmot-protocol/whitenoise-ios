import SwiftUI

private struct WNBackButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WNIconButton(
                        title: "Back",
                        systemImage: "chevron.backward",
                        chrome: .container
                    ) {
                        dismiss()
                    }
                    .disabled(isDisabled)
                }
            }
    }
}

extension View {
    /// Apply at the push site, not inside the destination, so a view that is
    /// also presented as a sheet keeps its own close affordance.
    ///
    /// `isDisabled` is for a step that is mid-flight, where leaving would strand
    /// work the screen started.
    func wnBackButton(isDisabled: Bool = false) -> some View {
        modifier(WNBackButtonModifier(isDisabled: isDisabled))
    }
}

#Preview("WNBackButton — Light") {
    NavigationStack {
        NavigationLink("Push") {
            Form {
                Section {
                    Text("Pushed screen")
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .wnBackButton()
        }
    }
}

#Preview("WNBackButton — Dark") {
    NavigationStack {
        NavigationLink("Push") {
            Form {
                Section {
                    Text("Pushed screen")
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .wnBackButton()
        }
    }
    .preferredColorScheme(.dark)
}
