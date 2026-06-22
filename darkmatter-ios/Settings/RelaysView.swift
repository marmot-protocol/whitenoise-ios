import SwiftUI
import MarmotKit

/// Account relay configuration + diagnostics.
///
/// Marmot owns the account relay lists. This screen reads the current
/// projection and sends edits back through Marmot, which publishes the updated
/// NIP-65 and inbox lists.
struct RelaysView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingUrl: String = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var savedAt: Date?

    @State private var lists: AccountRelayListsFfi?

    var body: some View {
        Form {
            accountRelaysSection
            publishedListsSection
        }
        .navigationTitle("Relays")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSaving {
                ProgressView().controlSize(.small)
            } else {
                EditButton()
            }
        }
        .task(id: appState.activeAccountRef) { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - Account relays

    private var accountRelaysSection: some View {
        Section {
            if lists == nil {
                ProgressView("Loading relays")
            } else {
                if currentRelays.isEmpty {
                    Text("No relays published")
                        .foregroundStyle(.secondary)
                }

                ForEach(currentRelays, id: \.self) { url in
                    Text(url).font(.system(.body, design: .monospaced))
                }
                .onDelete(perform: deleteRelays)

                HStack {
                    TextField("wss://relay.example.com", text: $pendingUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isSaving || lists == nil)
                    Button {
                        addPending()
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                    .disabled(!canAdd)
                }
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let savedAt {
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
        if let lists {
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

    // MARK: - Actions

    private var currentRelays: [String] {
        guard let lists else { return [] }
        return RelaySettings.editableRelays(from: lists)
    }

    private var canAdd: Bool {
        guard lists != nil,
              !isSaving,
              let normalized = RelaySettings.normalizedRelayURL(pendingUrl)
        else { return false }
        return !currentRelays.contains(normalized)
    }

    private func addPending() {
        guard let normalized = RelaySettings.normalizedRelayURL(pendingUrl), canAdd else { return }
        Task {
            if await saveRelays(currentRelays + [normalized]) {
                pendingUrl = ""
            }
        }
    }

    private func deleteRelays(at indexSet: IndexSet) {
        var next = currentRelays
        next.remove(atOffsets: indexSet)
        Task { await saveRelays(next) }
    }

    @MainActor
    private func reload() async {
        guard let ref = appState.activeAccountRef else {
            lists = nil
            return
        }
        do {
            lists = try await appState.currentMarmotClient().accountRelayLists(accountRef: ref)
        } catch {
            lists = nil
        }
    }

    @MainActor
    @discardableResult
    private func saveRelays(_ relays: [String]) async -> Bool {
        guard let accountRef = appState.activeAccountRef else { return false }
        let normalized = RelaySettings.normalizedRelayURLs(relays)
        guard !normalized.isEmpty else {
            saveError = L10n.string("Keep at least one relay.")
            Haptics.error()
            return false
        }

        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            lists = try await RelaySettings.saveAccountRelays(
                accountRef: accountRef,
                relays: normalized,
                currentLists: lists,
                manager: appState.marmot
            )
            savedAt = Date()
            Haptics.success()
            appState.present(.success(L10n.string("Relay lists updated")))
            return true
        } catch {
            if let failure = error as? RelaySettingsSaveFailure,
               let reloadedLists = failure.reloadedLists {
                lists = reloadedLists
            }
            Haptics.error()
            saveError = error.localizedDescription
            appState.present(.error(L10n.string("Relay update failed"), message: error.localizedDescription))
            return false
        }
    }
}
