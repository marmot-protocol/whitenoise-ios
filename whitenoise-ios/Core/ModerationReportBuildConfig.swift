import Foundation
import MarmotKit

/// IPF's private moderation-report destination for this build flavor. Reports
/// are gift-wrapped to the flavor's reports key and published only to the
/// White Noise seed relays, which IPF operates.
nonisolated struct ModerationReportBuildConfig: Equatable {
    static let pubkeyInfoKey = "WhiteNoiseModerationReportPubkey"

    let recipientPubkeyHex: String
    let relays: [String]

    static func current(bundle: Bundle = .main) -> ModerationReportBuildConfig? {
        current(rawPubkey: bundle.object(forInfoDictionaryKey: pubkeyInfoKey) as? String)
    }

    /// A missing or malformed key leaves reporting unconfigured, which MDK
    /// reports through `moderationReportingAvailable()`.
    static func current(
        rawPubkey: String?,
        relays: [String] = AppContainerConfig.seedRelays
    ) -> ModerationReportBuildConfig? {
        guard let raw = rawPubkey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let hex = Hex.normalized32Bytes(raw) ?? NostrProfileReference.pubkeyHex(fromBech32: raw.lowercased())
        guard let hex, Hex.is32Bytes(hex) else { return nil }
        return ModerationReportBuildConfig(recipientPubkeyHex: hex, relays: relays)
    }

    var ffi: ModerationReportConfigFfi {
        ModerationReportConfigFfi(recipientPubkey: recipientPubkeyHex, relays: relays)
    }
}
