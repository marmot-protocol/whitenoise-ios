import SwiftUI
import MarmotKit

/// Profile keys, with explicit consent before accessing the raw private key.
struct IdentityView: View {
    @Environment(AppState.self) private var appState
    @State private var model = IdentityViewModel()

    var body: some View {
        @Bindable var model = model
        Form {
            if let active = appState.activeAccount {
                publicKeySection(accountIdHex: active.accountIdHex)
                if active.localSigning {
                    privateKeySection
                    backupSection
                } else {
                    Section {
                        Text("This account cannot export a private key.")
                            .foregroundStyle(.secondary)
                            .wnGroupedCardRow(.only)
                    } header: {
                        Text("Private Key").wnSectionHeader()
                    }
                }
            } else {
                Section {
                    Text("No active account.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .localizedNavigationTitle("Profile Keys")
        .navigationBarTitleDisplayMode(.inline)
        .alert(model.rawKeyRequest?.action.confirmationTitle ?? "", isPresented: Binding(
            get: { model.rawKeyRequest != nil },
            set: { if !$0 { model.rawKeyRequest = nil } }
        ), presenting: model.rawKeyRequest) { request in
            Button("Cancel", role: .cancel) {}
            Button(request.action.title, role: .destructive) {
                Task { await model.performRawKeyRequest(request, using: appState) }
            }
        } message: { request in
            Text(request.action.confirmationMessage)
        }
        .sheet(isPresented: $model.showEncryptedExportSheet, onDismiss: model.encryptedSheetDismissed) {
            EncryptedNsecExportSheet(
                isExporting: model.exportInFlight,
                errorMessage: model.exportError,
                onCancel: { model.showEncryptedExportSheet = false },
                onExport: { passphrase in
                    Task { await model.exportEncryptedNsec(passphrase: passphrase, using: appState) }
                }
            )
            .appAppearance()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { model.exportShareText != nil },
            set: { if !$0 { model.exportShareText = nil } }
        )) {
            if let exportShareText = model.exportShareText {
                ActivityShareSheet(items: [exportShareText]) {
                    model.exportShareText = nil
                }
                .appAppearance()
            }
        }
        .task(id: model.copyFeedbackID) {
            guard model.copyFeedbackID != nil else { return }
            do { try await Task.sleep(for: WNCopyFeedback.resetDelay) } catch { return }
            model.privateKeyCopied = false
        }
        .onChange(of: appState.activeAccountRef) { _, _ in model.clearPresentation() }
        .onDisappear { model.clearPresentation() }
    }

    /// Offers the shareable npub when available, without falling back to account hex.
    private func publicKeySection(accountIdHex: String) -> some View {
        Section {
            if let npub = appState.npub(forAccountIdHex: accountIdHex) {
                HStack(spacing: 12) {
                    Text(npub)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(L10n.string("Public Key"))
                        .accessibilityValue(IdentityFormatter.short(npub))
                    WNCopyButton(value: npub, accessibilityTitle: L10n.formatted("Copy %@", L10n.string("Public Key"))) { copied in
                        WNCopyIcon(copied: copied)
                            .frame(width: WNInputMetrics.accessoryTarget, height: WNInputMetrics.accessoryTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                }
                .frame(minHeight: WNInputMetrics.height)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: WNInputMetrics.trailingInset))
                .wnGroupedCardRow(.only)
            } else {
                Text("Unavailable")
                    .foregroundStyle(.secondary)
                    .wnGroupedCardRow(.only)
            }
        } header: {
            Text("Public Key").wnSectionHeader()
        } footer: {
            Text("Share this key so people can find and connect with you.")
        }
    }

    private var privateKeySection: some View {
        Section {
            privateKeyRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } header: {
            Text("Private Key").wnSectionHeader()
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep this key private. Anyone with it can use your profile, and White Noise can’t recover it.")
                if let error = model.exportError, !model.showEncryptedExportSheet {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var backupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keep your private key somewhere safe. If you lose it, White Noise can’t recover it. We recommend protecting your backup with a password.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                exportButtons
            }
            .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
            .listRowSeparator(.hidden)
            .wnGroupedCardRow(.only)
        } header: {
            Text("Back Up Your Private Key").wnSectionHeader()
        }
    }

    private var exportButtons: some View {
        VStack(spacing: 12) {
            WNGrayButton(title: L10n.string("Back Up With a Password"), systemImage: "lock.doc") {
                model.hidePrivateKey()
                model.exportError = nil
                model.showEncryptedExportSheet = true
            }
            WNGrayButton(
                title: L10n.string("Back Up Without a Password"),
                systemImage: "arrow.down.document",
                isLoading: model.rawActionInFlight == .export
            ) {
                model.requestRawKey(.export, using: appState)
            }
        }
        .disabled(model.exportInFlight)
    }

    private var privateKeyRow: some View {
        HStack(spacing: WNInputMetrics.contentSpacing) {
            HStack(spacing: WNInputMetrics.contentSpacing) {
                privateKeyValue

                Button {
                    model.requestRawKey(.copy, using: appState)
                } label: {
                    WNCopyIcon(copied: model.privateKeyCopied)
                        .opacity(model.rawActionInFlight == .copy ? 0 : 1)
                        .overlay {
                            if model.rawActionInFlight == .copy { ProgressView() }
                        }
                        .frame(width: WNInputMetrics.accessoryTarget, height: WNInputMetrics.accessoryTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.exportInFlight)
                .accessibilityLabel(model.privateKeyCopied ? L10n.string("Copied") : L10n.string("Copy Private Key"))
                .accessibilityInputLabels([Text("Copy Private Key")])
            }
            .foregroundStyle(.primary)
            .padding(.leading, WNInputMetrics.leadingInset)
            .padding(.trailing, WNInputMetrics.trailingInset)
            .frame(minHeight: WNInputMetrics.height)
            .background(WNInputMetrics.groupedFill, in: Capsule())

            WNInputIconButton(
                title: model.revealedNsec == nil ? L10n.string("Show private key") : L10n.string("Hide private key"),
                systemImage: model.revealedNsec == nil ? "eye" : "eye.slash",
                isLoading: model.rawActionInFlight == .reveal
            ) {
                if model.revealedNsec != nil {
                    model.hidePrivateKey()
                } else {
                    model.requestRawKey(.reveal, using: appState)
                }
            }
            .disabled(model.exportInFlight)
        }
    }

    private var privateKeyValue: some View {
        Group {
            if let nsec = model.revealedNsec {
                Text(nsec)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                FittingPrivateKeyBullets()
            }
        }
        .font(.body.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .privacySensitive()
        .accessibilityHidden(true)
    }
}

private struct FittingPrivateKeyBullets: View {
    // One native text run lets privacy redaction obscure the whole value.
    private static let masks = (1...64).reversed().map { String(repeating: "•", count: $0) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.masks, id: \.self) { mask in
                Text(verbatim: mask)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
