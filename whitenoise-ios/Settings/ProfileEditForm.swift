import SwiftUI

/// Shared profile fields retain their minimum height when switching into editing.
struct ProfileEditForm<Avatar: View>: View {
    @Binding var displayName: String
    @Binding var nip05: String
    @Binding var about: String
    let isEditing: Bool
    let isLoading: Bool
    let isPublishing: Bool
    let hasLoadError: Bool
    @Binding var saveFailure: ProfileEditViewModel.SaveFailure?
    let addressError: String?
    let focusedField: FocusState<WNProfileField?>.Binding
    let saveDisabled: Bool
    let onReload: () -> Void
    let onRetrySave: () -> Void
    @ViewBuilder var avatar: () -> Avatar

    @State private var showPrivacyDetails = false
    @State private var nameFieldHeight: CGFloat = 0
    @State private var aboutFieldHeight: CGFloat = 0

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L10n.string("Loading…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasLoadError {
                ContentUnavailableView {
                    Label("Couldn’t load your profile", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry", action: onReload)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WNProfileFormContainer(
                    focusedField: focusedField.wrappedValue, nameFieldHeight: nameFieldHeight, aboutFieldHeight: aboutFieldHeight
                ) {
                    Form {
                        avatar()
                        fields.disabled(isPublishing)
                        if isEditing {
                            WNProfilePrivacySection {
                                clearFocus()
                                showPrivacyDetails = true
                            }
                            .disabled(isPublishing)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(.background)
        .wnProfileFailureAlert(
            Binding(get: { isEditing ? saveFailure : nil }, set: { saveFailure = $0 }),
            title: L10n.string("Couldn’t save your profile"),
            retryEnabled: !saveDisabled,
            message: { _ in L10n.string("Couldn’t save your profile details. Please try again.") },
            retry: { _ in onRetrySave() }
        )
        .sheet(isPresented: $showPrivacyDetails) {
            WNProfilePrivacyDetailsView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .onChange(of: isEditing) { _, _ in
            clearFocus()
            showPrivacyDetails = false
        }
        .onChange(of: isPublishing) { _, publishing in
            if publishing { clearFocus() }
        }
    }

    @ViewBuilder private var fields: some View {
        WNProfileNameSection(
            text: $displayName, focus: focusedField, isEditing: isEditing, nextField: .address,
            onHeightChange: { nameFieldHeight = $0 }
        )

        Section {
            Group {
                if isEditing {
                    TextField("Verified Nostr Address", text: $nip05)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused(focusedField, equals: .address)
                        .onSubmit { focusedField.wrappedValue = .about }
                } else {
                    Text(nip05.isEmpty ? L10n.string("Verified Nostr Address") : nip05)
                        .foregroundStyle(nip05.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .id(WNProfileField.address)
            .listRowBackground(Color(uiColor: .secondarySystemFill))
        } header: {
            Text("Verified Nostr Address")
        } footer: {
            if isEditing, let addressError {
                Text(addressError).foregroundStyle(.red)
            }
        }

        WNProfileAboutSection(text: $about, focus: focusedField, isEditing: isEditing) {
            aboutFieldHeight = $0
        }
    }

    private func clearFocus() {
        focusedField.wrappedValue = nil
    }
}

struct ProfileEditToolbar: ToolbarContent {
    @Environment(\.colorScheme) private var colorScheme

    let isEditing: Bool
    let isPublishing: Bool
    let cancelDisabled: Bool
    let saveDisabled: Bool
    let editDisabled: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onEdit: () -> Void

    private var primaryContentColor: Color {
        WNButtonPalette.primaryContent(
            colorScheme: colorScheme, isEnabled: !saveDisabled, isLoading: isPublishing
        )
    }

    var body: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .wnButtonChrome(emphasis: .secondary)
                    .disabled(cancelDisabled)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if isEditing {
                Button {
                    guard !isPublishing else { return }
                    onSave()
                } label: {
                    Text("Done")
                        .foregroundStyle(primaryContentColor)
                        .opacity(isPublishing ? 0 : 1)
                        .overlay {
                            if isPublishing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(primaryContentColor)
                            }
                        }
                }
                .wnPrimaryButtonStyle()
                .wnButtonChrome()
                .controlSize(.regular)
                .accessibilityLabel(isPublishing ? "Publishing…" : "Done")
                .disabled(saveDisabled && !isPublishing)
                .allowsHitTesting(!isPublishing)
            } else {
                Button("Edit", action: onEdit)
                    .wnButtonChrome(emphasis: .secondary)
                    .disabled(editDisabled)
            }
        }
    }
}
