import SwiftUI

private struct WNBackButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WNIconButton(title: "Back", systemImage: "chevron.backward") {
                        dismiss()
                    }
                }
            }
    }
}

extension View {
    /// Apply at the push site, not inside the destination, so a view that is
    /// also presented as a sheet keeps its own close affordance.
    func wnBackButton() -> some View {
        modifier(WNBackButtonModifier())
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
