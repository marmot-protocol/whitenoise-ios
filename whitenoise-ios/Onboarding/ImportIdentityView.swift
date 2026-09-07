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
    @State private var showScanner = false

    let showsCloseButton: Bool
    let onPreferredSheetExpansionChange: (Bool) -> Void

    init(
        showsCloseButton: Bool = false,
        onPreferredSheetExpansionChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.showsCloseButton = showsCloseButton
        self.onPreferredSheetExpansionChange = onPreferredSheetExpansionChange
    }

    private var normalizedIdentity: String {
        model.identity.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var keyState: KeyState {
        guard !normalizedIdentity.isEmpty else { return .empty }
        return Self.isPlausibleNsec(normalizedIdentity) ? .valid : .invalid
    }

    private var canSubmit: Bool {
        !model.isImporting && keyState == .valid
    }

    /// Accept only a checksum-valid NIP-19 encoding of a 32-byte private key.
    static func isPlausibleNsec(_ raw: String) -> Bool {
        NostrProfileReference.normalizedNsec(raw) != nil
    }

    static func consumeIdentityForImport(_ raw: inout String) -> String {
        let normalized = NostrProfileReference.normalizedNsec(raw) ?? ""
        raw = ""
        return normalized
    }

    static func redactedImportError(_ message: String) -> String {
        message
            .replacing(/nsec1[a-z0-9]+/.ignoresCase(), with: "nsec1…")
            .replacing(/[0-9a-fA-F]{32,}/, with: "…")
    }

    var body: some View {
        Group {
            if let setup = appState.pendingAccountSetup, appState.isAccountSetupPresented {
                AccountSetupView(model: setup, onClose: { dismiss() })
                    .onAppear { onPreferredSheetExpansionChange(true) }
            } else {
                signInForm
            }
        }
    }

    @ViewBuilder
    private var signInForm: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading) {
                Text("Private Key")
                    .font(.headline)
                    .padding(.leading)

                HStack {
                    privateKeyField(identity: $model.identity)

                    if !model.isImporting && (isKeyFocused || normalizedIdentity.isEmpty) {
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
            }
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.top)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .disabled(model.isImporting)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            WNButton(title: "Sign In", isLoading: model.isImporting) {
                Task {
                    await model.runImport(using: appState, dismiss: { dismiss() })
                }
            }
            .disabled(!canSubmit && !model.isImporting)
            .accessibilityLabel(model.isImporting ? "Signing In" : "Sign In")
            .accessibilityValue(model.isImporting ? "In progress" : "")
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.bottom)
        }
        .navigationDestination(isPresented: $showScanner) {
            PrivateKeyQRScanner { payload in
                model.clearPastedClipboardToken()
                model.identity = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                showScanner = false
            }
        }
        .onChange(of: showScanner) {
            onPreferredSheetExpansionChange(showScanner || isKeyFocused)
        }
        .onChange(of: isKeyFocused) {
            onPreferredSheetExpansionChange(showScanner || isKeyFocused)
        }
        .interactiveDismissDisabled(model.isImporting)
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

    private func privateKeyField(identity: Binding<String>) -> some View {
        HStack(spacing: 0) {
            PasteAwareSecureField(
                text: identity,
                isFocused: $isKeyFocused,
                showsAccessory: !model.isImporting,
                onClear: { model.clearPastedClipboardToken() },
                onPaste: { token, resultingIdentity in
                    model.recordPastedClipboardToken(
                        token,
                        resultingIdentity: resultingIdentity
                    )
                },
                onSubmit: {
                    guard canSubmit else { return }
                    Task {
                        await model.runImport(using: appState, dismiss: { dismiss() })
                    }
                }
            )
            .privacySensitive()
        }
        .padding(.leading)
        .frame(height: 50)
        .background(Color(uiColor: .secondarySystemFill), in: .capsule)
        .disabled(model.isImporting)
        .contentShape(.capsule)
        .onTapGesture {
            guard !model.isImporting else { return }
            isKeyFocused = true
        }
    }
}

private struct PrivateKeyQRScanner: View {
    @State private var error: String?

    let onScan: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRScannerView(
                onScan: { payload in
                    onScan(payload)
                },
                onError: { error = $0 }
            )
            .ignoresSafeArea()

            if let error {
                ContentUnavailableView {
                    Label("QR Scanning Unavailable", systemImage: "camera.fill")
                } description: {
                    Text(error)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
