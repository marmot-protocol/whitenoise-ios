import SwiftUI
import MarmotKit

/// Current device package and additional packages observed on this profile's relays.
struct KeyPackagesView: View {
    @Environment(AppState.self) private var appState
    @State private var model = KeyPackagesViewModel()

    var body: some View {
        Form {
            Section("Current Key Package") {
                if model.isLoading && !model.hasLoaded {
                    ProgressView("Loading key packages")
                } else if model.loadError != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't load this screen", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await model.reload(using: appState) }
                        }
                    }
                } else if model.maintenanceLoadError != nil {
                    Text("Unavailable").foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.reload(using: appState) } }
                } else if let current = model.presentation.current {
                    packageDetails(
                        identifier: current.identifier,
                        publishedAt: current.publishedAt,
                        bytes: current.bytes
                    )
                } else {
                    Text("No current key package found for this device.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await model.publishNew(using: appState) }
                } label: {
                    if model.isPublishing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                    } else {
                        Label("Publish New Key Package", systemImage: "shippingbox.and.arrow.backward")
                    }
                }
                .disabled(model.isPublishing || !model.deletingEventIds.isEmpty || appState.activeAccountRef == nil)
            } footer: {
                Text("Publishes a new key package so this profile can receive group invitations.")
            }

            if model.loadError == nil && !model.presentation.otherRelayPackages.isEmpty {
                Section {
                    ForEach(model.presentation.otherRelayPackages, id: \.eventIdHex) { package in
                        otherPackageRow(package)
                    }
                } header: {
                    if model.maintenanceLoadError == nil {
                        Text("Other Key Packages on Relays")
                    } else {
                        Text("Key Packages")
                    }
                } footer: {
                    if model.maintenanceLoadError == nil {
                        Text("These packages were found on this profile’s relays and differ from this device’s current package.")
                    }
                }
            }
        }
        .localizedNavigationTitle("Key Packages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isLoading && model.hasLoaded {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
    }

    private func packageDetails(identifier: String, publishedAt: UInt64?, bytes: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shortHex(identifier))
                .font(.body.monospaced())
            HStack(spacing: 6) {
                if let publishedAt, let published = Self.publishedDescription(publishedAt) {
                    Text(published)
                }
                if let bytes, bytes > 0 {
                    if publishedAt != nil && publishedAt != 0 {
                        Text("·")
                    }
                    Text(Self.byteCount(bytes))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func otherPackageRow(_ package: AccountKeyPackageFfi) -> some View {
        let isDeleting = model.deletingEventIds.contains(package.eventIdHex)
        return VStack(alignment: .leading, spacing: 4) {
            packageDetails(
                identifier: package.eventIdHex,
                publishedAt: package.publishedAt,
                bytes: package.keyPackageBytes
            )
            if !package.sourceRelays.isEmpty {
                Text(Self.sanitizedRelays(package.sourceRelays))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .opacity(isDeleting ? 0.5 : 1)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await model.delete(package, using: appState) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDeleting || model.isPublishing)
        }
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
    static func sanitizedRelays(_ relays: [String]) -> String {
        relays.prefix(4)
            .compactMap { ContentSanitizer.relayDisplayLine($0, maxLength: 120) }
            .joined(separator: ", ")
    }

}
