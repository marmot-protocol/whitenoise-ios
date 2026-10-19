import SwiftUI

/// Sign-out presentation, confirmation, and keyboard-aware scrolling.
struct SignOutForm<ProfileSummary: View>: View {
    @Binding var shouldWipeData: Bool
    @Binding var confirmation: String
    let profileName: String
    let isBusy: Bool
    let canSignOut: Bool
    let error: String?
    let onClose: () -> Void
    let onSignOut: () -> Void
    @ViewBuilder let profileSummary: () -> ProfileSummary
    @FocusState private var confirmationFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ScrollTarget: Hashable {
        case wipeConfirmation
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                signOutForm
                    .onChange(of: confirmationFocused) {
                        revealConfirmation(using: proxy)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                        // Focus changes before keyboard avoidance finishes resizing the form.
                        revealConfirmation(using: proxy)
                    }
                    .onScrollGeometryChange(for: CGSize.self) { geometry in
                        geometry.visibleRect.size
                    } action: { oldSize, newSize in
                        if newSize.height < oldSize.height || newSize.width != oldSize.width {
                            revealConfirmation(using: proxy)
                        }
                    }
            }
            .navigationTitle("Sign Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .disabled(isBusy)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy)
        .onChange(of: shouldWipeData) { _, wiping in
            if !wiping { confirmationFocused = false }
        }
    }

    private var signOutForm: some View {
        Form {
            Section {
                profileSummary()
                Toggle("Wipe Local Data", isOn: $shouldWipeData)
                    .disabled(isBusy)
                    .accessibilityIdentifier("sign-out.wipe-data-toggle")
            } footer: {
                if !shouldWipeData {
                    Text("Your profile and chats will stay on this device.")
                }
            }

            if shouldWipeData {
                Section {
                    VStack(alignment: .leading, spacing: 20) {
                        wipeWarning
                        confirmationInput
                        inlineError
                        signOutButton
                    }
                    .padding(20)
                    .listRowInsets(EdgeInsets())
                    .id(ScrollTarget.wipeConfirmation)
                }
            } else {
                if error != nil {
                    Section { inlineError }
                }
                Section {
                    signOutButton
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    private func revealConfirmation(using proxy: ScrollViewProxy) {
        guard shouldWipeData, confirmationFocused else { return }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(ScrollTarget.wipeConfirmation, anchor: .bottom)
        }
    }

    private var wipeWarning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text("You’ll lose all chats")
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text("This profile’s data will be erased from this device. Chats can’t be restored. You’ll need new invitations. Copies held by others or relays won’t be erased.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var confirmationInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile name")
                .font(.subheadline.weight(.medium))
                .padding(.leading, WNInputMetrics.leadingInset)
            WNInput(
                placeholder: L10n.string("Profile name"),
                text: $confirmation,
                surface: .filled,
                submitLabel: .done,
                focus: $confirmationFocused
            )
            .disabled(isBusy)
            .accessibilityIdentifier("wipe-profile.confirmation-field")
            Text(confirmationHint)
                .font(.footnote)
                .padding(.horizontal, WNInputMetrics.leadingInset)
        }
    }

    @ViewBuilder
    private var inlineError: some View {
        if let error {
            Text(error).foregroundStyle(.orange)
        }
    }

    private var signOutButton: some View {
        WNButton(
            title: "Sign Out",
            emphasis: shouldWipeData ? .destructive : .primary,
            size: .standard,
            isLoading: isBusy,
            surface: shouldWipeData ? .filled : .automatic,
            action: submit
        )
        .disabled(!isBusy && !canSignOut)
        .accessibilityLabel(busyTitle)
        .accessibilityIdentifier(shouldWipeData ? "wipe-profile.confirm" : "sign-out.keep-data")
    }

    private func submit() {
        confirmationFocused = false
        onSignOut()
    }

    private var busyTitle: LocalizedStringKey {
        guard isBusy else { return "Sign Out" }
        return shouldWipeData ? "Signing out and wiping data…" : "Signing out…"
    }

    private var confirmationHint: AttributedString {
        // Style the argument, even if the name also appears in the surrounding copy.
        let placeholder = "\u{FFFC}"
        var hint = AttributedString(L10n.formatted("Type %@ to confirm.", placeholder))
        hint.foregroundColor = .secondary
        if let range = hint.range(of: placeholder) {
            var name = AttributedString(profileName)
            name.foregroundColor = Color(uiColor: .label)
            hint.replaceSubrange(range, with: name)
        }
        return hint
    }
}
