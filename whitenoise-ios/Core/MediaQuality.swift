import Foundation

/// How aggressively outgoing media (images, voice notes) is compressed before
/// send. The setting is a ceiling, not a target — a source already smaller
/// than the level's target ships as-is (no upscaling, no bitrate inflation).
/// Levels and knobs mirror the Android client so both platforms produce the
/// same output for the same setting.
///
/// Privacy floor (orthogonal to this knob): every level — including
/// `original` — strips identifying photo metadata. On this client images are
/// re-rendered through the draft pipeline, which drops EXIF/GPS/maker notes
/// wholesale; `original` skips the downscale but keeps the stripping
/// re-encode.
///
/// Video has no re-encode path in this client, so video is always sent as-is
/// regardless of this setting — the quality levels apply to images and voice
/// notes only.
nonisolated enum MediaQuality: String, CaseIterable {
    case low
    case standard
    case high
    case original

    static let defaultQuality: MediaQuality = .standard

    var imageMaxEdgePx: CGFloat {
        switch self {
        case .low: return 1024
        case .standard: return 2048
        case .high: return 4096
        case .original: return .greatestFiniteMagnitude
        }
    }

    var imageJPEGQuality: CGFloat {
        switch self {
        case .low: return 0.70
        case .standard: return 0.85
        case .high: return 0.92
        case .original: return 1.0
        }
    }

    var audioBitrateBps: Int {
        switch self {
        case .low: return 32_000
        case .standard: return 64_000
        case .high, .original: return 96_000
        }
    }

    /// Descending JPEG qualities tried until the encoded image fits the byte
    /// cap; the level's quality is the ceiling, the last entry the floor.
    var imageJPEGQualityLadder: [CGFloat] {
        let floor: CGFloat = 0.52
        let steps = [imageJPEGQuality, imageJPEGQuality - 0.12, imageJPEGQuality - 0.24]
            .filter { $0 > floor }
        return steps + [floor]
    }
}

/// Reads and persists the send-quality preference. Device-scoped (matching
/// the Android client's preference scope): outbound compression is a
/// data/quality trade-off of the device and its connection, not an identity.
nonisolated enum MediaQualityStore {
    static let storageKey = "media.sendQuality"

    static func quality(defaults: UserDefaults = .standard) -> MediaQuality {
        guard let raw = defaults.string(forKey: storageKey),
              let quality = MediaQuality(rawValue: raw)
        else { return .defaultQuality }
        return quality
    }

    static func setQuality(_ quality: MediaQuality, defaults: UserDefaults = .standard) {
        HostSettingsSaveTiming.measure { defaults.set(quality.rawValue, forKey: storageKey) }
    }
}
