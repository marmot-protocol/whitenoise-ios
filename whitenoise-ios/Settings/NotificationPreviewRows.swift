import SwiftUI

/// Lock-screen exposure control for message notifications. The choice is
/// per-device rather than per-account, so it does not move with the account
/// switcher the rest of this screen follows.
struct NotificationPreviewRows: View {
    let mode: NotificationPreviewMode
    let isEnabled: Bool
    let setMode: (NotificationPreviewMode) -> Void

    var body: some View {
        Group {
            Picker(selection: Binding(get: { mode }, set: setMode)) {
                ForEach(NotificationPreviewMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notification Preview")
                    Text("Choose what appears in notifications.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .pickerStyle(.inline)

            Label(mode.example, systemImage: "bell.badge")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .disabled(!isEnabled)
    }
}

#Preview("Notification preview modes") {
    @Previewable @State var mode = NotificationPreviewMode.generic

    Form {
        Section {
            NotificationPreviewRows(mode: mode, isEnabled: true) { mode = $0 }
        }
    }
}
