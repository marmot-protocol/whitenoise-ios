import SwiftUI
import MarmotKit

/// Edit the user's default relay set. Persisted in UserDefaults; future
/// builds will sync this through Nostr kind:10002 / NIP-65.
struct RelaysView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingUrl: String = ""
    @State private var isPublishing = false
    @State private var publishError: String?
    @State private var publishedAt: Date?

    var body: some View {
        Form {
            Section {
                ForEach(appState.defaultRelays, id: \.self) { url in
                    Text(url)
                        .font(.system(.body, design: .monospaced))
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
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .disabled(!canAdd)
                }
            } footer: {
                Text("These relays are used when publishing key packages, relay lists, and profile metadata. Group chats also use the relays embedded in their own routing component.")
                    .font(.footnote)
            }

            Section {
                Button {
                    Task { await republish() }
                } label: {
                    HStack {
                        if isPublishing {
                            ProgressView().controlSize(.small)
                        }
                        Text(isPublishing ? "Publishing…" : "Republish to Relays")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPublishing || appState.activeAccountRef == nil)
            }

            if let publishError {
                Section {
                    Label(publishError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if let publishedAt {
                Section {
                    Label("Published \(publishedAt.formatted(.relative(presentation: .named)))",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Relays")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }

    private var canAdd: Bool {
        let trimmed = pendingUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("wss://") || trimmed.lowercased().hasPrefix("ws://")
        else { return false }
        return !appState.defaultRelays.contains(trimmed)
    }

    private func addPending() {
        let trimmed = pendingUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAdd, !trimmed.isEmpty else { return }
        appState.defaultRelays.append(trimmed)
        pendingUrl = ""
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
        } catch {
            publishError = error.localizedDescription
        }
        isPublishing = false
    }
}
