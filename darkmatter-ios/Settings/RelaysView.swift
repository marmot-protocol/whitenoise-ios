import SwiftUI
import MarmotKit

/// Relay configuration + diagnostics.
///
/// Three layers:
///  1. Default relays — the set used for *new* account creation and *new*
///     groups when the user doesn't already have relays configured.
///  2. Published relay lists — the NIP-65 / inbox / key-package lists this
///     account has actually published (read from marmot-app's projection).
///  3. Relay diagnostics — live relay-plane connection health.
struct RelaysView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingUrl: String = ""
    @State private var isPublishing = false
    @State private var publishError: String?
    @State private var publishedAt: Date?

    @State private var lists: AccountRelayListsFfi?
    @State private var health: RelayHealthFfi?

    var body: some View {
        Form {
            defaultRelaysSection
            republishSection
            publishedListsSection
            diagnosticsSection
        }
        .navigationTitle("Relays")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .task(id: appState.activeAccountRef) { await reload() }
    }

    // MARK: - Default relays

    private var defaultRelaysSection: some View {
        Section {
            ForEach(appState.defaultRelays, id: \.self) { url in
                Text(url).font(.system(.body, design: .monospaced))
            }
            .onDelete { indexSet in
                var next = appState.defaultRelays
                next.remove(atOffsets: indexSet)
                appState.defaultRelays = next
            }

            HStack {
                TextField("wss://relay.example.com", text: $pendingUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))
                Button {
                    addPending()
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                }
                .disabled(!canAdd)
            }
        } header: {
            Text("Default Relays")
        } footer: {
            Text("These are the defaults used when you create a new identity or start a new group and don't already have relays configured. Existing groups use the relays embedded in their own routing.")
                .font(.footnote)
        }
    }

    private var republishSection: some View {
        Section {
            Button {
                Task { await republish() }
            } label: {
                HStack {
                    if isPublishing { ProgressView().controlSize(.small) }
                    Text(isPublishing ? "Publishing…" : "Republish to Relays")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isPublishing || appState.activeAccountRef == nil)

            if let publishError {
                Label(publishError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            if let publishedAt {
                Label("Published \(publishedAt.formatted(.relative(presentation: .named)))",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout)
            }
        }
    }

    // MARK: - Published lists

    @ViewBuilder
    private var publishedListsSection: some View {
        if let lists {
            Section {
                relayListRow("NIP-65", systemImage: "list.bullet", list: lists.nip65)
                relayListRow("Inbox", systemImage: "tray.and.arrow.down", list: lists.inbox)
                relayListRow("Key Package", systemImage: "key", list: lists.keyPackage)
            } header: {
                Text("Published Relay Lists")
            } footer: {
                if lists.complete {
                    Text("All relay lists are published.").font(.footnote)
                } else {
                    Text("Missing: \(lists.missing.joined(separator: ", ")). Tap Republish to publish them.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func relayListRow(_ title: String, systemImage: String, list: RelayListFfi) -> some View {
        DisclosureGroup {
            if list.relays.isEmpty {
                Text("Not published")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list.relays, id: \.self) { relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(title).font(.callout)
                Spacer()
                Text("\(list.relays.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            if let health {
                diagnosticRow("Connected", "\(health.connected) / \(health.totalRelays)",
                              tint: health.connected > 0 ? .green : .secondary)
                if health.connecting > 0 {
                    diagnosticRow("Connecting", "\(health.connecting)", tint: .orange)
                }
                diagnosticRow("Disconnected", "\(health.disconnected)",
                              tint: health.disconnected > 0 ? .orange : .secondary)
                if health.sleeping > 0 {
                    diagnosticRow("Sleeping", "\(health.sleeping)", tint: .secondary)
                }
                if health.banned > 0 {
                    diagnosticRow("Banned", "\(health.banned)", tint: .red)
                }
                diagnosticRow("Connection attempts",
                              "\(health.connectionSuccesses)/\(health.connectionAttempts)",
                              tint: .secondary)
                diagnosticRow("Backend", health.sdkBacked ? "Nostr SDK" : "Directory only",
                              tint: .secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading relay health…").font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Relay Diagnostics")
                Spacer()
                Button {
                    Task { health = await appState.marmot.relayHealth() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
            }
        } footer: {
            Text("Live connection state of the relay plane across all subscribed relays.")
                .font(.footnote)
        }
    }

    private func diagnosticRow(_ title: String, _ value: String, tint: Color) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    // MARK: - Actions

    private var canAdd: Bool {
        let t = pendingUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.hasPrefix("wss://") || t.hasPrefix("ws://") else { return false }
        return !appState.defaultRelays.contains(pendingUrl.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func addPending() {
        let trimmed = pendingUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAdd, !trimmed.isEmpty else { return }
        appState.defaultRelays.append(trimmed)
        pendingUrl = ""
    }

    @MainActor
    private func reload() async {
        guard let ref = appState.activeAccountRef else { return }
        lists = try? appState.marmot.accountRelayLists(accountRef: ref)
        health = await appState.marmot.relayHealth()
    }

    @MainActor
    private func republish() async {
        guard let accountRef = appState.activeAccountRef else { return }
        isPublishing = true
        publishError = nil
        do {
            try await appState.marmot.publishRelayLists(
                accountRef: accountRef,
                defaultRelays: appState.defaultRelays,
                bootstrapRelays: appState.defaultRelays
            )
            publishedAt = Date()
            Haptics.success()
            appState.present(.success("Relay lists republished"))
            lists = try? appState.marmot.accountRelayLists(accountRef: accountRef)
        } catch {
            Haptics.error()
            publishError = error.localizedDescription
            appState.present(.error("Republish failed", message: error.localizedDescription))
        }
        isPublishing = false
    }
}
