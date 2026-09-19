import Foundation
import Network

/// The kinds of media a bubble can carry. Each call site already knows its
/// own type (image bubble → `.image`, voice bubble → `.audio`), so the gate
/// is passed the literal type rather than re-deriving it from MIME.
nonisolated enum MediaAutoDownloadType: String, CaseIterable {
    case image
    case audio
    case video
    case document
}

/// The network conditions an auto-download decision is made against. A live
/// connection can match several at once (cellular that is also constrained);
/// the decision applies the most-restrictive matching rule. Mirrors the
/// Android client's matrix, minus its roaming row — this platform exposes no
/// public roaming signal, so the constrained/expensive flags stand in as the
/// "user is paying for data" condition.
nonisolated enum MediaAutoDownloadNetwork: String, CaseIterable {
    case wifi
    case mobile
    case metered

    /// Pure mapping from a live path's flags to every condition it matches.
    /// Wi-Fi that is expensive (a personal hotspot) counts as metered, as
    /// does any connection in Low Data Mode (`isConstrained`). Cellular is
    /// NOT automatically metered — the system flags all cellular as
    /// expensive, and stacking metered onto every mobile connection would
    /// make the mobile row meaningless. Empty means no/unknown connection,
    /// which `shouldAutoDownload` treats as "do not auto-download".
    static func matching(
        usesWifi: Bool,
        usesCellular: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> Set<MediaAutoDownloadNetwork> {
        var networks: Set<MediaAutoDownloadNetwork> = []
        if usesWifi {
            networks.insert(.wifi)
            if isExpensive { networks.insert(.metered) }
        }
        if usesCellular {
            networks.insert(.mobile)
        }
        if isConstrained { networks.insert(.metered) }
        return networks
    }
}

/// The user-facing choice for one media type. The settings surface offers a
/// per-type level rather than raw matrix cells; each level projects onto a
/// canonical set of enabled networks. Wi-Fi-only deliberately excludes
/// metered connections (hotspots, Low Data Mode) — the level in between
/// exists to save data, and those are exactly the connections asking for it.
nonisolated enum MediaAutoDownloadLevel: CaseIterable, Equatable {
    case never
    case wifiOnly
    case wifiAndCellular

    var enabledNetworks: Set<MediaAutoDownloadNetwork> {
        switch self {
        case .never: return []
        case .wifiOnly: return [.wifi]
        case .wifiAndCellular: return [.wifi, .mobile, .metered]
        }
    }
}

/// Pure, immutable per-type × per-network auto-download matrix. Holds only
/// the set of enabled `(type, network)` cells; everything else is derived.
/// Decision semantics and serialization mirror the Android client so the
/// same stored preference means the same behavior on both platforms.
nonisolated struct MediaAutoDownloadMatrix: Equatable {
    private var enabled: Set<Cell>

    struct Cell: Hashable {
        let type: MediaAutoDownloadType
        let network: MediaAutoDownloadNetwork
    }

    init(enabled: Set<Cell>) {
        self.enabled = enabled
    }

    func isEnabled(_ type: MediaAutoDownloadType, on network: MediaAutoDownloadNetwork) -> Bool {
        enabled.contains(Cell(type: type, network: network))
    }

    func toggling(_ type: MediaAutoDownloadType, on network: MediaAutoDownloadNetwork, to on: Bool) -> Self {
        var next = enabled
        if on {
            next.insert(Cell(type: type, network: network))
        } else {
            next.remove(Cell(type: type, network: network))
        }
        return Self(enabled: next)
    }

    /// Snaps a type's cells to its user-facing level. Mobile-enabled means
    /// everywhere; otherwise Wi-Fi-enabled means Wi-Fi-only — so matrices
    /// written by an older per-cell surface still read as a sensible level.
    func level(for type: MediaAutoDownloadType) -> MediaAutoDownloadLevel {
        if isEnabled(type, on: .mobile) { return .wifiAndCellular }
        if isEnabled(type, on: .wifi) { return .wifiOnly }
        return .never
    }

    /// Replaces every cell for `type` with the level's canonical networks.
    func setting(_ type: MediaAutoDownloadType, to level: MediaAutoDownloadLevel) -> Self {
        var next = enabled.filter { $0.type != type }
        for network in level.enabledNetworks {
            next.insert(Cell(type: type, network: network))
        }
        return Self(enabled: next)
    }

    /// Most-restrictive decision: auto-download `type` only when
    /// `activeNetworks` is non-empty AND the type is enabled for every
    /// network the live connection matches — if metered is OFF for a type,
    /// that wins over Wi-Fi being ON. Empty (unknown/offline) is
    /// conservative: no auto-download.
    func shouldAutoDownload(
        _ type: MediaAutoDownloadType,
        activeNetworks: Set<MediaAutoDownloadNetwork>
    ) -> Bool {
        guard !activeNetworks.isEmpty else { return false }
        return activeNetworks.allSatisfy { isEnabled(type, on: $0) }
    }

    /// Flat, order-stable `type:network` CSV — the same wire format the
    /// Android client persists, so the preference is portable in meaning.
    func toPreference() -> String {
        MediaAutoDownloadType.allCases.flatMap { type in
            MediaAutoDownloadNetwork.allCases.compactMap { network in
                isEnabled(type, on: network) ? "\(type.rawValue):\(network.rawValue)" : nil
            }
        }
        .joined(separator: ",")
    }

    static func fromPreference(_ raw: String?) -> Self? {
        guard let raw else { return nil }
        var cells: Set<Cell> = []
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let type = MediaAutoDownloadType(rawValue: String(parts[0])),
                  let network = MediaAutoDownloadNetwork(rawValue: String(parts[1]))
            else { continue }
            cells.insert(Cell(type: type, network: network))
        }
        return Self(enabled: cells)
    }

    /// Reference-messenger defaults: photos and audio download everywhere,
    /// video and files only on unmetered Wi-Fi.
    static let defaultMatrix = Self(enabled: [])
        .setting(.image, to: .wifiAndCellular)
        .setting(.audio, to: .wifiAndCellular)
        .setting(.video, to: .wifiOnly)
        .setting(.document, to: .wifiOnly)
}

/// Persistence + live-network resolution for the matrix. Device-scoped like
/// the send-quality preference — download policy is a property of the device
/// and its connection.
@MainActor
@Observable
final class MediaAutoDownloadStore {
    static let shared = MediaAutoDownloadStore()
    static let storageKey = "media.autoDownloadMatrix"
    /// Posted on the offline→online transition — the app's cue to run the
    /// same relay catch-up it runs on foreground activation.
    static let connectivityRestored = Notification.Name("MediaAutoDownloadStore.connectivityRestored")

    private(set) var matrix: MediaAutoDownloadMatrix
    private(set) var activeNetworks: Set<MediaAutoDownloadNetwork> = []
    /// Raw path satisfaction — distinct from `activeNetworks`, which is empty
    /// both when offline and on interface types the matrix doesn't model.
    private(set) var isOnline = true
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private var accountIdHex: String?

    /// The matrix is an account-scoped preference; the bare key holds the
    /// pre-account default and the no-account fallback.
    static func storageKey(accountIdHex: String?) -> String {
        guard let accountIdHex, !accountIdHex.isEmpty else { return storageKey }
        return "\(storageKey):\(accountIdHex)"
    }

    /// Reloads the matrix for the account whose preference should govern.
    func setActiveAccount(_ accountIdHex: String?) {
        guard self.accountIdHex != accountIdHex else { return }
        self.accountIdHex = accountIdHex
        matrix = MediaAutoDownloadMatrix.fromPreference(
            defaults.string(forKey: Self.storageKey(accountIdHex: accountIdHex))
        ) ?? .defaultMatrix
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.matrix = MediaAutoDownloadMatrix.fromPreference(defaults.string(forKey: Self.storageKey))
            ?? .defaultMatrix
        monitor.pathUpdateHandler = { [weak self] path in
            let networks = MediaAutoDownloadNetwork.matching(
                usesWifi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                usesCellular: path.usesInterfaceType(.cellular),
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                self.activeNetworks = satisfied ? networks : []
                if satisfied, !self.isOnline {
                    NotificationCenter.default.post(name: Self.connectivityRestored, object: nil)
                }
                self.isOnline = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "media.autodownload.path"))
    }

    func setLevel(_ level: MediaAutoDownloadLevel, for type: MediaAutoDownloadType) {
        matrix = matrix.setting(type, to: level)
        defaults.set(matrix.toPreference(), forKey: Self.storageKey(accountIdHex: accountIdHex))
    }

    func resetToDefaults() {
        matrix = .defaultMatrix
        defaults.removeObject(forKey: Self.storageKey(accountIdHex: accountIdHex))
    }

    var attachmentPolicyRevision: String {
        "\(matrix.toPreference())/\(activeNetworks.map(\.rawValue).sorted().joined(separator: ","))"
    }

    func allowsBackgroundAttachments(accountID: String) -> Bool {
        let preference = MediaAutoDownloadMatrix.fromPreference(
            defaults.string(forKey: Self.storageKey(accountIdHex: accountID))) ?? .defaultMatrix
        return MediaAutoDownloadType.allCases.allSatisfy {
            preference.shouldAutoDownload($0, activeNetworks: activeNetworks)
        }
    }

    func shouldAutoDownload(_ type: MediaAutoDownloadType) -> Bool {
        matrix.shouldAutoDownload(type, activeNetworks: activeNetworks)
    }
}

/// Voice messages always auto-download — they are small, conversational, and
/// both major reference messengers exempt them from the matrix. Other audio
/// attachments honor the audio row.
nonisolated enum AudioAutoDownloadPolicy {
    /// The wire carries no trustworthy voice marker yet, so the
    /// always-download bypass requires a locally-known, plausible duration —
    /// unknown audio honors the matrix (an explicit Never must win over an
    /// unverifiable guess). Becomes exact for received notes once the media
    /// reference carries bounded metadata (engine follow-up).
    static let maxVoiceMessageSeconds: Double = 600

    static func isVoiceMessage(durationSeconds: Double?) -> Bool {
        guard let durationSeconds, durationSeconds.isFinite else { return false }
        return durationSeconds > 0 && durationSeconds <= maxVoiceMessageSeconds
    }

    static func shouldPrefetch(isVoiceMessage: Bool, matrixAllows: Bool) -> Bool {
        isVoiceMessage || matrixAllows
    }
}
