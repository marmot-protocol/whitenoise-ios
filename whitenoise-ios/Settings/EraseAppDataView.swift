import SwiftUI

struct EraseAppDataView: View {
    var isRecovery = false
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ProfileExitConfirmation.erasePhrase()
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This can’t be undone", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Every profile and all local chats, media, drafts, keys, and settings will be removed from this iPhone.")
                }
                if !isRecovery { Section {
                    Text(phrase).font(.headline).textSelection(.enabled)
                    TextField("Confirmation phrase", text: $confirmation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text("Enter the three words exactly to continue.") } }
                if isRecovery { Text("Erasure didn’t finish. Some data may remain. Try again.").foregroundStyle(.orange) }
                if let error { Text(error).foregroundStyle(.orange) }
                Section {
                    Button(role: .destructive) {
                        guard !busy, isRecovery || ProfileExitConfirmation.matches(confirmation, expected: phrase) else { return }
                        busy = true
                        error = nil
                        Task {
                            do {
                                try await appState.eraseAppData()
                                dismiss()
                            } catch {
                                self.error = L10n.string("Erasure didn’t finish. Some data may remain. Try again.")
                            }
                            busy = false
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "Erasing…" : isRecovery ? "Retry" : "Erase").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    .disabled(busy || (!isRecovery && !ProfileExitConfirmation.matches(confirmation, expected: phrase)))
                }
            }
            .disabled(busy)
            .navigationTitle("Erase App Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close").disabled(busy)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(busy)
    }
}
