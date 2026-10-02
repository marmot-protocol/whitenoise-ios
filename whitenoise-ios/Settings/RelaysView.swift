import SwiftUI
import MarmotKit

/// Account relay configuration + diagnostics.
///
/// Marmot owns the account relay lists. This screen reads the current
/// projection and sends edits back through Marmot. The account (NIP-65) and
/// inbox lists are edited and published separately. All load/save/validation
/// lives in `RelaysViewModel`; this view is pure rendering.
struct RelaysView: View {
    @Environment(AppState.self) private var appState
    @State private var model = RelaysViewModel()
    @State private var addRelayTarget: RelayListTarget?

    var body: some View {
        Form {
            accountRelaysSection
            inboxRelaysSection
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
        .sheet(item: $addRelayTarget) { target in
            AddRelaySettingsSheet(existingRelays: model.relays(for: target)) { url in
                model.pendingUrl = url
                model.addPending(to: target, using: appState)
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

                editableRelayRows(.nip65)
            }

            keepOneRelayError(.nip65)
        } header: {
            Text("Account Relays")
        } footer: {
            Text("Other Nostr apps find your posts and profile on these relays. Edits are published as your NIP-65 relay list.")
                .font(.footnote)
        }
    }

    // MARK: - Inbox relays

    @ViewBuilder
    private var inboxRelaysSection: some View {
        if model.lists != nil {
            Section {
                if model.currentInboxRelays.isEmpty {
                    Text("No relays published")
                        .foregroundStyle(.secondary)
                }

                editableRelayRows(.inbox)
                keepOneRelayError(.inbox)
            } header: {
                Text("Inbox Relays")
            } footer: {
                Text("People send you chat invitations on these relays. Edits are published as your inbox relay list.")
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func editableRelayRows(_ target: RelayListTarget) -> some View {
        ForEach(Array(model.relays(for: target).enumerated()), id: \.offset) { _, url in
            Text(RelaySettings.editableRelayDisplay(url))
                .font(.system(.body, design: .monospaced))
        }
        .onDelete { model.deleteRelays(at: $0, from: target, using: appState) }

        Button {
            addRelayTarget = target
        } label: {
            Label("Add Relay", systemImage: "plus.circle")
        }
        .disabled(model.isSaving || model.lists == nil)
    }

    @ViewBuilder
    private func keepOneRelayError(_ target: RelayListTarget) -> some View {
        if model.saveErrorTarget == target,
           model.saveError == L10n.string("Keep at least one relay."),
           let saveError = model.saveError {
            Label(saveError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
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
                    TextField("wss://relay.example.com", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.body.monospaced())
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
