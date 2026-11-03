import SwiftUI

struct EncryptedNsecExportSheet: View {
    let isExporting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onExport: (String) -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case password, confirmation }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .confirmation }
                        .wnGroupedCardRow(.first)
                    SecureField("Confirm Password", text: $confirmation)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .confirmation)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .wnGroupedCardRow(.last)
                } footer: {
                    if !confirmation.isEmpty && password != confirmation {
                        Label("Passwords don’t match.", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text("Use a long, unique password. You’ll need it to open the encrypted backup. White Noise never stores it.")
                    }
                }
                .disabled(isExporting)

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .wnGroupedCardRow(.only)
                    }
                }
            }
            .localizedNavigationTitle("Encrypted Private Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        focusedField = nil
                        onExport(password)
                    } label: {
                        Text("Export")
                            .opacity(isExporting ? 0 : 1)
                            .overlay { if isExporting { ProgressView() } }
                    }
                    .wnPrimaryButtonStyle()
                    .disabled(isExporting || password.isEmpty || password != confirmation)
                }
            }
            .onAppear { focusedField = .password }
        }
        .interactiveDismissDisabled(isExporting)
    }
}
