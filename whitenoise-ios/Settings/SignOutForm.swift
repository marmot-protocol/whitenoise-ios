import SwiftUI

/// Shared sign-out and profile-deletion confirmation.
struct SignOutForm<ProfileSummary: View>: View {
    var intent: AccountExitIntent = .signOut
    @Binding var shouldWipeData: Bool
    @Binding var confirmation: String
    let profileName: String
    let isBusy: Bool
    let canSignOut: Bool
    let error: String?
    let onClose: () -> Void
    let onSignOut: () -> Void
    @ViewBuilder let profileSummary: () -> ProfileSummary
    @State private var isKeyboardVisible = false
    @State private var confirmationHeight: CGFloat = 0
    @FocusState private var confirmationFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ScrollTarget: Hashable {
        case wipeConfirmation
    }

    private var isDeletingProfile: Bool { intent == .deleteProfile }
    private var isWiping: Bool { isDeletingProfile || shouldWipeData }
    private var navigationTitle: LocalizedStringKey { isDeletingProfile ? "Delete Profile" : "Sign Out" }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                exitForm
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaPadding(.bottom, isKeyboardVisible ? BottomInputChromeLayout.keyboardInset : 0)
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
                    .onChange(of: confirmationHeight) {
                        revealConfirmation(using: proxy)
                    }
            }
            .navigationTitle(navigationTitle)
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
        .trackKeyboardVisibility($isKeyboardVisible, animatesChanges: false)
        .onChange(of: shouldWipeData) { _, wiping in
            if !wiping { confirmationFocused = false }
        }
    }

    @ViewBuilder
    private var exitForm: some View {
        if isDeletingProfile {
            deletionForm
        } else {
            signOutForm
        }
    }

    private var deletionForm: some View {
        Form {
            Section {
                profileSummary()
                    .padding(20)
                    .listRowInsets(EdgeInsets())
                    .wnGroupedCardRow(.first)
                deletionExplanation
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .listRowInsets(EdgeInsets())
                    .wnGroupedCardRow(.middle)
                VStack(alignment: .leading, spacing: 20) {
                    confirmationInput
                    inlineError
                    signOutButton
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .listRowInsets(EdgeInsets())
                .wnGroupedCardRow(.last)
                .id(ScrollTarget.wipeConfirmation)
            }
            .listRowSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var signOutForm: some View {
        Form {
            Section {
                profileSummary()
                Toggle("Wipe Local Data", isOn: $shouldWipeData)
                    .disabled(isBusy)
                    .accessibilityIdentifier("sign-out.wipe-data-toggle")
            } footer: {
                if !isWiping {
                    Text("Your profile and chats will stay on this device.")
                }
            }

            if isWiping {
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
        guard isWiping, confirmationFocused else { return }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(ScrollTarget.wipeConfirmation, anchor: .bottom)
        }
    }

    private var deletionExplanation: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete Profile")
                    .font(.title.bold())
                Text("This signs you out and permanently removes this profile’s data from this device.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            deletionDetail(
                "Chats and media",
                text: "Your local chats, media, and drafts will be deleted. Signing in again won’t restore them."
            )
            deletionDetail(
                "Secret key",
                text: "Your secret key will be removed from this device. You’ll need a saved copy to sign in again."
            )
            deletionDetail(
                "Groups",
                text: "You’ll leave your groups and need new invitations to rejoin."
            )
            deletionDetail(
                "Profile settings",
                text: "This profile’s local settings will be removed. Your other profiles are unaffected."
            )
            deletionDetail(
                "Copies elsewhere",
                text: "Messages and profile information held by other people or independent relays may remain."
            )
            deletionDetail(
                "Your Nostr identity remains",
                text: "Your identity comes from a cryptographic key, not an account controlled by White Noise. We can remove it from this device, but cannot erase it across Nostr."
            )
        }
        .foregroundStyle(.primary)
    }

    private func deletionDetail(_ title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(text)
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
            Text("This profile’s chats, media, and secret key will be erased from this device. You’ll leave your groups. Chats can’t be restored, and you’ll need new invitations.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Copies held by others or relays won’t be erased.")
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            confirmationHeight = $0
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
            title: actionTitle,
            emphasis: isWiping ? .destructive : .primary,
            size: .standard,
            isLoading: isBusy,
            surface: isWiping ? .filled : .automatic,
            action: submit
        )
        .disabled(!isBusy && !canSignOut)
        .accessibilityLabel(busyTitle)
        .accessibilityIdentifier(isWiping ? "wipe-profile.confirm" : "sign-out.keep-data")
    }

    private func submit() {
        confirmationFocused = false
        onSignOut()
    }

    private var actionTitle: LocalizedStringKey {
        if isDeletingProfile { return "Delete Profile" }
        return isWiping ? "Sign Out and Delete Data" : "Sign Out"
    }

    private var busyTitle: LocalizedStringKey {
        guard isBusy else { return actionTitle }
        if isDeletingProfile { return "Deleting…" }
        return isWiping ? "Signing out and wiping data…" : "Signing out…"
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
