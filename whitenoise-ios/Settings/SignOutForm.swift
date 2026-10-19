import SwiftUI

/// Shared by the real sign-out sheet and the isolated debug previews.
struct SignOutForm<ProfileSummary: View>: View {
    @Binding var shouldWipeData: Bool
    @Binding var confirmation: String
    let profileName: String
    let isBusy: Bool
    let canSignOut: Bool
    let error: AccountExitError?
    let onSignOut: () -> Void
    let onClose: () -> Void
    @ViewBuilder let profileSummary: ProfileSummary
    @FocusState private var confirmationFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    profileSummary
                    Toggle("Wipe Data From This Device", isOn: $shouldWipeData)
                        .disabled(isBusy)
                        .accessibilityIdentifier("sign-out.wipe-data-toggle")
                } footer: {
                    if shouldWipeData {
                        Text("This profile and all local data will be permanently removed. Signing in again won’t restore previous chats. You’ll need a new invitation to each chat.")
                    } else {
                        Text("This profile and its local data will stay on this device.")
                    }
                }

                if shouldWipeData {
                    Section {
                        TextField("Profile name", text: $confirmation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($confirmationFocused)
                            .disabled(isBusy)
                            .accessibilityIdentifier("wipe-profile.confirmation-field")
                    } header: {
                        Text("Enter Profile Name").wnSectionHeader()
                    } footer: {
                        Text(confirmationHint)
                    }
                }

                if let error {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(error.title).font(.headline)
                                if let message = error.message {
                                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmationFocused = false
                        onSignOut()
                    } label: {
                        Text("Sign Out")
                            .font(.body.weight(.regular))
                            .frame(maxWidth: .infinity)
                            .opacity(isBusy ? 0 : 1)
                            .overlay {
                                if isBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                            }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .disabled(!isBusy && !canSignOut)
                    .allowsHitTesting(!isBusy)
                    .accessibilityLabel(busyTitle)
                    .accessibilityIdentifier(shouldWipeData ? "wipe-profile.confirm" : "sign-out.keep-data")
                }
            }
            .navigationTitle("Sign Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isBusy {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(isBusy ? .hidden : .visible)
        .interactiveDismissDisabled(isBusy)
        .onChange(of: shouldWipeData) { _, wiping in
            if !wiping {
                confirmation = ""
                confirmationFocused = false
            }
        }
    }

    private var confirmationHint: AttributedString {
        // Style the argument, even when a profile name also occurs in the surrounding copy.
        let placeholder = "\u{FFFC}"
        var hint = AttributedString(L10n.formatted("Enter %@ exactly to confirm.", placeholder))
        hint.foregroundColor = .secondary
        if let range = hint.range(of: placeholder) {
            var name = AttributedString(profileName)
            name.foregroundColor = Color(uiColor: .label)
            hint.replaceSubrange(range, with: name)
        }
        return hint
    }

    /// Keep the action label in the hierarchy while showing its spinner.
    private var busyTitle: LocalizedStringKey {
        guard isBusy else { return "Sign Out" }
        return shouldWipeData ? "Signing out and wiping data…" : "Signing out…"
    }

}
