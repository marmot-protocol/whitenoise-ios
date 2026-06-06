import Foundation
import Observation
import MarmotKit

@Observable
final class ProfileCache {
    private(set) var displayNames: [String: String] = [:]
    private(set) var profiles: [String: UserProfileMetadataFfi] = [:]
    private(set) var npubs: [String: String] = [:]

    @ObservationIgnored private var directoryFetchesInFlight: Set<String> = []

    func cachedProfile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        profiles[id]
    }

    func knownDisplayName(
        forAccountIdHex id: String,
        profile: UserProfileMetadataFfi?,
        projectedName: String?,
        localAccountLabel: String?
    ) -> String? {
        if let profile, let name = Self.name(from: profile) {
            return name
        }
        if let cached = displayNames[id] {
            return cached
        }
        if let name = ProfileSanitizer.displayName(projectedName) {
            displayNames[id] = name
            return name
        }
        if let localAccountLabel, !localAccountLabel.isEmpty {
            return localAccountLabel
        }
        return nil
    }

    func displayName(forAccountIdHex id: String, knownName: String?) -> String {
        knownName ?? IdentityFormatter.short(id)
    }

    func avatarURL(for profile: UserProfileMetadataFfi?) -> URL? {
        ProfileSanitizer.imageURL(profile?.picture)
    }

    func cacheProfile(_ profile: UserProfileMetadataFfi, for id: String) {
        profiles[id] = profile
        if let name = Self.name(from: profile) {
            displayNames[id] = name
        }
    }

    func cacheProjectedDisplayName(_ rawName: String?, for id: String) {
        if let name = ProfileSanitizer.displayName(rawName) {
            displayNames[id] = name
        }
    }

    func beginDirectoryFetch(for id: String) -> Bool {
        guard !directoryFetchesInFlight.contains(id) else { return false }
        directoryFetchesInFlight.insert(id)
        return true
    }

    func finishDirectoryFetch(for id: String) {
        directoryFetchesInFlight.remove(id)
    }

    func npub(forAccountIdHex id: String, projected: String?) -> String {
        if let cached = npubs[id] { return cached }
        guard let projected else { return id }
        npubs[id] = projected
        return projected
    }

    private static func name(from profile: UserProfileMetadataFfi) -> String? {
        ProfileSanitizer.displayName(profile.displayName ?? profile.name)
    }
}
