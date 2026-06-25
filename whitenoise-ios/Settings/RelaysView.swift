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

    var body: some View {
        Form {
            accountRelaysSection
            publishedListsSection
        }
        .navigationTitle("Relays")
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
    }

    // MARK: - Account relays

    private var accountRelaysSection: some View {
        Section {
            if model.lists == nil {
                ProgressView("Loading relays")
            } else {
                if model.currentRelays.isEmpty {
                    Text("No relays published")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.currentRelays, id: \.self) { url in
                    Text(url).font(.system(.body, design: .monospaced))
                }
                .onDelete { model.deleteRelays(at: $0, using: appState) }

                HStack {
                    TextField(
                        "wss://relay.example.com",
                        text: Binding(get: { model.pendingUrl }, set: { model.pendingUrl = $0 })
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                        .disabled(model.isSaving || model.lists == nil)
                    Button {
                        model.addPending(using: appState)
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                    .disabled(!model.canAdd)
                }
            }

            if let saveError = model.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let savedAt = model.savedAt {
                Label(
                    L10n.formatted("Saved %@", savedAt.formatted(.relative(presentation: .named))),
                    systemImage: "checkmark.seal.fill"
                )
                    .foregroundStyle(.green)
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
