import MarmotKit
import SwiftUI
import UIKit

/// Import an existing local-signing Nostr identity. `npub...` is only a public
/// identity and is intentionally not accepted as a sign-in credential.
struct ImportIdentityView: View {
    private enum KeyState {
        case empty
        case invalid
        case valid
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = ImportIdentityViewModel()
    @State private var isKeyFocused = false
    @State private var isKeyboardVisible = false
    @State private var showScanner = false
    @State private var openingSetup: AccountSetupModel?
    @State private var isRecoveringSetup = false
    @State private var showsPrivateKeyForm = false
    @State private var recoveryMessage: String?
    @State private var selectedRecoveryProfile: AccountSummaryFfi?
    @State private var recoveredInSession: [AccountSummaryFfi] = []

    let isPushed: Bool
    let onPreferredSheetExpansionChange: (Bool) -> Void
    let onChatsOpened: (() -> Void)?

    init(
        isPushed: Bool = false,
        onPreferredSheetExpansionChange: @escaping (Bool) -> Void = { _ in },
        onChatsOpened: (() -> Void)? = nil
    ) {
        self.isPushed = isPushed
        self.onPreferredSheetExpansionChange = onPreferredSheetExpansionChange
        self.onChatsOpened = onChatsOpened
    }

    private var normalizedIdentity: String {
        model.identity.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var keyState: KeyState {
        guard !normalizedIdentity.isEmpty else { return .empty }
        return Self.isPlausibleNsec(normalizedIdentity) ? .valid : .invalid
    }

    private var isBusy: Bool { model.isImporting || isRecoveringSetup }

    private var canSubmit: Bool {
        !isBusy && keyState == .valid
    }

    private var readyProfiles: [AccountSummaryFfi] {
        OnboardingRecoveryPresentation.readyProfiles(
            accounts: appState.accounts,
            recoveredInSession: recoveredInSession,
            recoveryIDs: Set(appState.onboardingRecoveryAccounts.map(\.accountIdHex)),
            unfinishedIDs: Set(appState.accountSetupSnapshots.map(\.accountIdHex))
        )
    }

    private var hasRecoveryProfiles: Bool {
        !appState.onboardingRecoveryAccounts.isEmpty || !readyProfiles.isEmpty
    }

    /// Accept only a checksum-valid NIP-19 encoding of a 32-byte private key.
    nonisolated static func isPlausibleNsec(_ raw: String) -> Bool {
        NostrProfileReference.normalizedNsec(raw) != nil
    }

    static func consumeIdentityForImport(_ raw: inout String) -> String {
        let normalized = NostrProfileReference.normalizedNsec(raw) ?? ""
        raw = ""
        return normalized
    }

    var body: some View {
        Group {
            if let setup = openingSetup ?? (appState.isAccountSetupPresented ? appState.pendingAccountSetup : nil) {
                AccountSetupView(
                    model: setup,
                    isOpeningChats: openingSetup != nil,
                    onClose: { dismiss() },
                    onOpenChats: { openChats(setup) }
                )
                .onAppear { onPreferredSheetExpansionChange(true) }
            } else if !showsPrivateKeyForm && (isRecoveringSetup || hasRecoveryProfiles) {
                OnboardingRecoverySection(
                    isPushed: isPushed,
                    isWorking: $isRecoveringSetup,
                    readyProfiles: readyProfiles,
                    onRecovered: { account in
                        var recovered = account
                        recovered.signedOut = true
                        recovered.running = false
                        recoveredInSession.removeAll { $0.accountIdHex == account.accountIdHex }
                        recoveredInSession.append(recovered)
                    },
                    onProfilesChanged: { message in
                        guard !hasRecoveryProfiles else { return }
                        showPrivateKeyForm(account: nil, message: message)
                    },
                    onSignIn: showPrivateKeyForm
                )
                .onAppear { onPreferredSheetExpansionChange(true) }
            } else {
                signInForm
            }
        }
        .task(id: appState.runtimeGeneration) {
            guard openingSetup == nil, !appState.isAccountSetupPresented else { return }
            try? await appState.refreshAccounts(refreshUnreadSummaries: false)
        }
    }

    private func showPrivateKeyForm(account: AccountSummaryFfi?, message: String?) {
        selectedRecoveryProfile = account
        recoveryMessage = message
        showsPrivateKeyForm = true
        onPreferredSheetExpansionChange(false)
    }

    private func openChats(_ setup: AccountSetupModel) {
        guard openingSetup == nil else { return }
        // Keep the checklist through account refresh and the outgoing sheet transition.
        openingSetup = setup
        Task {
            await appState.finishAccountSetup()
            if appState.pendingAccountSetup != nil || appState.activeAccount?.accountIdHex != setup.accountID {
                openingSetup = nil
            } else {
                onChatsOpened?()
            }
        }
    }

    @ViewBuilder
    private var signInForm: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading) {
                if let selectedRecoveryProfile {
                    OnboardingRecoveryProfileSummary(account: selectedRecoveryProfile)
                        .padding(.bottom, 16)
                }
                if let recoveryMessage {
                    Text(verbatim: recoveryMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                }
                Text("Private Key")
                    .font(.headline)
                    .padding(.leading)

                HStack {
                    privateKeyField(identity: $model.identity)

                    if !isBusy && (isKeyFocused || normalizedIdentity.isEmpty) {
                        Button {
                            if isKeyFocused {
                                isKeyFocused = false
                            } else {
                                showScanner = true
                            }
                        } label: {
                            Image(systemName: isKeyFocused ? "xmark" : "qrcode.viewfinder")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .compatibleGlassCircleButtonStyle()
                        .controlSize(.large)
                        .preservesKeyboardOnTap()
                        .transition(.opacity)
                        .accessibilityLabel(isKeyFocused ? "Dismiss Keyboard" : "Scan QR Code")
                    }
                }
                .animation(.default, value: isKeyFocused)
                .animation(.default, value: normalizedIdentity.isEmpty)

                if keyState == .invalid {
                    Text("That private key isn't valid. Check it and try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.leading)
                } else {
                    Text("It starts with nsec.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading)
                }
                signInAction
                    .padding(.top)
            }
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.top)
            .safeAreaPadding(.bottom)
        }
        .compatibleBottomScrollEdgeEffectHidden()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WNIconButton(
                    title: isPushed || hasRecoveryProfiles ? "Back" : "Close",
                    systemImage: isPushed || hasRecoveryProfiles ? "chevron.backward" : "xmark",
                    chrome: .container
                ) {
                    if hasRecoveryProfiles {
                        isKeyFocused = false
                        showsPrivateKeyForm = false
                        selectedRecoveryProfile = nil
                        recoveryMessage = nil
                        onPreferredSheetExpansionChange(true)
                    } else {
                        dismiss()
                    }
                }
                .disabled(isBusy)
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PrivateKeyQRScanner { payload in
                    model.clearPastedClipboardToken()
                    model.identity = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    showScanner = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WNIconButton(title: "Close", systemImage: "xmark", chrome: .container) {
                            showScanner = false
                        }
                        .accessibilityIdentifier("sign-in.scanner.close")
                    }
                }
            }
            .appAppearance()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: isKeyFocused) {
            // Coordinate compact sizing with keyboard dismissal, not the focus change.
            guard showsPrivateKeyForm || !hasRecoveryProfiles else { return }
            guard isKeyFocused || !isKeyboardVisible else { return }
            onPreferredSheetExpansionChange(isKeyFocused)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            guard isKeyboardVisible else { return }
            isKeyboardVisible = false
            if !isKeyFocused && (showsPrivateKeyForm || !hasRecoveryProfiles) {
                withAnimation(KeyboardFrameChange.animation(from: notification)) {
                    onPreferredSheetExpansionChange(false)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .alert(
            "Recover incomplete setup?",
            isPresented: $model.showIncompleteSetupRecoveryConfirmation
        ) {
            Button("Recover Identity", role: .destructive) {
                model.resolveIncompleteSetupRecoveryConfirmation(approved: true)
            }
            Button("Cancel", role: .cancel) {
                model.resolveIncompleteSetupRecoveryConfirmation(approved: false)
            }
        } message: {
            Text("A previous sign-in stopped before setup finished. Recovery removes that incomplete local setup and tries again. A KeyPackage from the failed attempt may remain published on relays.")
        }
        .onDisappear {
            model.scrubDismissedImportState()
        }
        .background(.background)
    }

    private var signInAction: some View {
        WNOnboardingButton(title: "Sign In", isLoading: model.isImporting) {
            isKeyFocused = false
            Task {
                await model.runImport(using: appState, dismiss: completeImport)
            }
        }
        .disabled(!canSubmit && !model.isImporting)
        .accessibilityLabel(model.isImporting ? "Signing In" : "Sign In")
    }

    private func completeImport() {
        if let onChatsOpened {
            onChatsOpened()
        } else {
            dismiss()
        }
    }

    private func privateKeyField(identity: Binding<String>) -> some View {
        HStack(spacing: 0) {
            PasteAwareSecureField(
                text: identity,
                isFocused: $isKeyFocused,
                showsAccessory: !isBusy,
                placeholder: selectedRecoveryProfile == nil
                    ? L10n.string("Enter private key")
                    : L10n.string("Enter this profile’s private key"),
                onFocusRequest: { onPreferredSheetExpansionChange(true) },
                onPaste: { token, resultingIdentity in
                    model.recordPastedClipboardToken(
                        token,
                        resultingIdentity: resultingIdentity
                    )
                },
                onSubmit: {
                    guard canSubmit else { return }
                    isKeyFocused = false
                    Task {
                        await model.runImport(using: appState, dismiss: completeImport)
                    }
                }
            )
            .privacySensitive()
        }
        .padding(.leading)
        .frame(height: 50)
        .background(Color(uiColor: .secondarySystemFill), in: .capsule)
        .preservesKeyboardOnTap()
        .disabled(isBusy)
    }
}
