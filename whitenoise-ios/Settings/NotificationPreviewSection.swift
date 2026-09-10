import SwiftUI

/// Lock-screen exposure control for message notifications. The choice is
/// per-device rather than per-account, so it does not move with the account
/// switcher the rest of this screen follows.
struct NotificationPreviewSection: View {
    let mode: NotificationPreviewMode
    let isEnabled: Bool
    let setMode: (NotificationPreviewMode) -> Void

    var body: some View {
        Section {
            Picker("Notification Preview", selection: Binding(get: { mode }, set: setMode)) {
                ForEach(NotificationPreviewMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Label(mode.example, systemImage: "bell.badge")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Preview").wnSectionHeader()
        } footer: {
            Text("Choose how much message information appears on the Lock Screen.")
        }
        .disabled(!isEnabled)
    }
}

#Preview("Notification preview modes") {
    @Previewable @State var mode = NotificationPreviewMode.generic

    Form {
        NotificationPreviewSection(mode: mode, isEnabled: true) { mode = $0 }
    }
}
