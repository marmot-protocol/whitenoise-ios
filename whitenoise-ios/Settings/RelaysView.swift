import SwiftUI
import MarmotKit

/// Account relay configuration + diagnostics.
///
/// Marmot owns the account relay lists. This screen reads the current
/// projection and sends edits back through Marmot, which publishes the updated
/// NIP-65 and inbox lists. All load/save/validation lives in `RelaysViewModel`;
/// this view is pure rendering.
struct RelaysView: View {
    @Environment(AppState.self) private var appState
    @State private var model = RelaysViewModel()
    @State private var isShowingAddRelay = false

    var body: some View {
        Form {
            accountRelaysSection
            publishedListsSection
        }
        .localizedNavigationTitle("Relays")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isSaving {
                ProgressView().controlSize(.small)
            } else {
                EditButton()
            }
        }
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
        .sheet(isPresented: $isShowingAddRelay) {
            AddRelaySettingsSheet(existingRelays: model.currentRelays) { url in
                model.pendingUrl = url
                model.addPending(using: appState)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Account relays

    private var accountRelaysSection: some View {
        Section {
            if model.lists == nil {
                if model.loadError != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't load this screen", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Button("Retry") {
                            Task { await model.reload(using: appState) }
                        }
                    }
                } else {
                    ProgressView("Loading relays")
                }
            } else {
                if model.currentRelays.isEmpty {
                    Text("No relays published")
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(model.currentRelays.enumerated()), id: \.offset) { _, url in
                    Text(RelaySettings.editableRelayDisplay(url))
                        .font(.system(.body, design: .monospaced))
                }
                .onDelete { model.deleteRelays(at: $0, using: appState) }

                Button {
                    isShowingAddRelay = true
                } label: {
                    Label("Add Relay", systemImage: "plus.circle")
                }
                .disabled(model.isSaving || model.lists == nil)
            }

            if model.saveError == L10n.string("Keep at least one relay."),
               let saveError = model.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Account Relays")
        } footer: {
            Text("Read from Marmot's account relay lists. Edits are published through Marmot to your NIP-65 and inbox relay lists.")
                .font(.footnote)
        }
    }

    // MARK: - Published lists

    @ViewBuilder
    private var publishedListsSection: some View {
        if let lists = model.lists {
            Section {
                relayListRow("NIP-65", systemImage: "list.bullet", list: lists.nip65)
                relayListRow("Inbox", systemImage: "tray.and.arrow.down", list: lists.inbox)
            } header: {
                Text("Published Relay Lists")
            } footer: {
                if lists.complete {
                    Text("All relay lists are published.").font(.footnote)
                } else {
                    Text(
                        L10n.formatted(
                            "Missing: %@. Add a relay to publish them.",
                            RelaySettings.missingRelayLabels(lists.missing).joined(separator: ", ")
                        )
                    )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func relayListRow(_ title: LocalizedStringKey, systemImage: String, list: RelayListFfi) -> some View {
        DisclosureGroup {
            // Stable per-row identity by position. Sanitized display strings can
            // collide (distinct raw relays sanitize to the same line), so id: \.self
            // would produce duplicate SwiftUI identities on hostile relay input.
            ForEach(Array(RelaySettings.publishedRelayRows(list.relays).enumerated()), id: \.offset) { _, relay in
                Text(relay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(relay == RelaySettings.notPublishedMessage ? .secondary : .primary)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(title).font(.callout)
                Spacer()
                Text(L10n.formatted("%lld", Int64(list.relays.count)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

private struct AddRelaySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    let existingRelays: [String]
    let onAdd: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WNInput(
                        placeholder: L10n.string("wss://relay.example.com"),
                        text: $url
                    )
                    .keyboardType(.URL)
                    .font(.body.monospaced())
                    .wnInputRow()
                } header: {
                    Text("Relay URL")
                } footer: {
                    Text("Use a secure WebSocket relay URL beginning with wss://.")
                }
            }
            .localizedNavigationTitle("Add Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(url)
                        dismiss()
                    }
                    .wnPrimaryButtonStyle()
                    .disabled(!canAdd)
                }
            }
        }
    }

    private var canAdd: Bool {
        guard let normalized = RelaySettings.normalizedRelayURL(url) else {
            return false
        }
        return !existingRelays.contains(normalized)
    }
}
