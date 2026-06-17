import SwiftUI
import MarmotKit

/// MLS KeyPackage management for the active account.
///
/// Lists key packages Marmot knows about — both those published from this
/// device and any additional copies found on the account's key-package
/// relays — and lets the user delete individual packages or publish a fresh
/// one. All work goes through the MarmotKit bindings; relay-sourced fields
/// are treated as untrusted and clamped at display time.
struct KeyPackagesView: View {
    @Environment(AppState.self) private var appState

    @State private var packages: [AccountKeyPackageFfi] = []
    @State private var lists: AccountRelayListsFfi?
    @State private var isLoading = false
    @State private var isPublishing = false
    @State private var deletingEventIds: Set<String> = []
    @State private var loadError: String?

    var body: some View {
        Form {
            if isLoading && packages.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading key packages")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else {
                if !localPackages.isEmpty {
                    Section {
                        ForEach(localPackages, id: \.eventIdHex) { pkg in
                            keyPackageRow(pkg)
                        }
                    } header: {
                        Text("Published from this device")
                    } footer: {
                        Text("Other accounts use these key packages to invite you into MLS groups. \"Synced\" means the package is also visible on your account outbox relays; \"Local only\" means this device has it but the relays didn't return it just now (it may not be replicated, or the relays didn't respond).")
                            .font(.footnote)
                    }
                }

                if !relayOnlyPackages.isEmpty {
                    Section {
                        ForEach(relayOnlyPackages, id: \.eventIdHex) { pkg in
                            keyPackageRow(pkg)
                        }
                    } header: {
                        Text("Discovered on relays")
                    } footer: {
                        Text("Found on your account outbox relays but not stored on this device — most likely published from another device or an older session. Delete to retire it.")
                            .font(.footnote)
                    }
                }

                if packages.isEmpty {
                    Section {
                        Text("No key packages found.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await publishNew() }
                    } label: {
                        if isPublishing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Publishing…")
                            }
                        } else {
                            Label("Publish New Key Package", systemImage: "plus.square.on.square")
                        }
                    }
                    .disabled(isPublishing || appState.activeAccountRef == nil)
                } footer: {
                    Text("Publishes a fresh KeyPackage event to your account outbox relays.")
                        .font(.footnote)
                }

                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
        }
        .navigationTitle("Key Packages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isLoading && !packages.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: appState.activeAccountRef) { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - Derived

    private var localPackages: [AccountKeyPackageFfi] {
        packages.filter(\.local).sorted { $0.publishedAt > $1.publishedAt }
    }

    private var relayOnlyPackages: [AccountKeyPackageFfi] {
        packages.filter { !$0.local && $0.relay }
                .sorted { $0.publishedAt > $1.publishedAt }
    }

    // MARK: - Row

    @ViewBuilder
    private func keyPackageRow(_ pkg: AccountKeyPackageFfi) -> some View {
        let isDeleting = deletingEventIds.contains(pkg.eventIdHex)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EVENT ID")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(shortHex(pkg.eventIdHex))
                        .font(.system(.callout, design: .monospaced))
                }
                Spacer()
                badge(for: pkg)
            }
            HStack(spacing: 10) {
                if let published = Self.publishedDescription(pkg.publishedAt) {
                    Text(published)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if pkg.keyPackageBytes > 0 {
                    Text(Self.byteCount(pkg.keyPackageBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !pkg.sourceRelays.isEmpty {
                Text(Self.sanitizedRelays(pkg.sourceRelays))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .opacity(isDeleting ? 0.5 : 1)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await delete(pkg) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDeleting)
        }
    }

    @ViewBuilder
    private func badge(for pkg: AccountKeyPackageFfi) -> some View {
        if pkg.local && pkg.relay {
            badgeLabel(L10n.string("Synced"), tint: .green)
        } else if pkg.local {
            badgeLabel(L10n.string("Local only"), tint: .orange)
        } else {
            badgeLabel(L10n.string("Relay only"), tint: .blue)
        }
    }

    private func badgeLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - Formatting

    private func shortHex(_ hex: String) -> String {
        let capped = String(hex.prefix(64))
        guard capped.count > 14 else { return capped }
        return "\(capped.prefix(8))…\(capped.suffix(6))"
    }

    /// `ts` is a relay-influenced timestamp (seconds since epoch). Anyone can
    /// publish anything to a relay, so clamp into the signed range before the
    /// `TimeInterval` conversion rather than trusting the raw value — matching
    /// the defensive `Int64(clamping:)` projection in
    /// `PrivacySecuritySettingsProjection`.
    static func publishedDescription(_ ts: UInt64) -> String? {
        guard ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(Int64(clamping: ts)))
        return L10n.formatted("Published %@", date.formatted(.relative(presentation: .named)))
    }

    /// `bytes` is a relay-influenced size. `Int64(bytes)` traps on hostile
    /// values near `UInt64.max`; clamp at the display boundary instead, as
    /// `PrivacySecuritySettingsProjection.byteCount` already does.
    static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// Strip spoofing characters and cap length on relay-supplied strings.
    /// Anyone can publish anything to a relay — we only render a small preview
    /// here, never the raw payload. The previous ad-hoc filter only removed
    /// C0/DEL and let bidi / zero-width codepoints through, so relay URLs could
    /// be visually spoofed (#53). Reuse ProfileSanitizer.singleLine, the shared
    /// display-boundary sanitizer.
    static func sanitizedRelays(_ relays: [String]) -> String {
        relays.prefix(4)
            .compactMap { ProfileSanitizer.singleLine($0, maxLength: 120) }
            .joined(separator: ", ")
    }

    // MARK: - Actions

    @MainActor
    private var bootstrapRelays: [String] {
        lists.map(RelaySettings.bootstrapRelays(from:)) ?? MarmotClient.seedRelays
    }

    @MainActor
    private func reload() async {
        guard let ref = appState.activeAccountRef else {
            packages = []
            lists = nil
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            lists = try appState.marmot.accountRelayLists(accountRef: ref)
            packages = try await appState.marmot.accountKeyPackages(
                accountRef: ref,
                bootstrapRelays: bootstrapRelays
            )
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func publishNew() async {
        guard let ref = appState.activeAccountRef else { return }
        isPublishing = true
        defer { isPublishing = false }

        do {
            _ = try await appState.marmot.publishNewKeyPackage(accountRef: ref)
            Haptics.success()
            appState.present(.success(L10n.string("New key package published")))
            await reload()
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Publish failed"), message: error.localizedDescription))
        }
    }

    @MainActor
    private func delete(_ pkg: AccountKeyPackageFfi) async {
        guard let ref = appState.activeAccountRef else { return }
        let eventId = pkg.eventIdHex
        deletingEventIds.insert(eventId)
        defer { deletingEventIds.remove(eventId) }

        do {
            _ = try await appState.marmot.deleteAccountKeyPackage(
                accountRef: ref,
                eventIdHex: eventId,
                relays: bootstrapRelays
            )
            Haptics.success()
            appState.present(.success(L10n.string("Key package deleted")))
            await reload()
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Delete failed"), message: error.localizedDescription))
        }
    }
}
