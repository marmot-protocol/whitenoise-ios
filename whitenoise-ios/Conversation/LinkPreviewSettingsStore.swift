import Foundation
import Observation

@MainActor
@Observable
final class LinkPreviewSettingsStore {
    static let shared = LinkPreviewSettingsStore()
    static let storageKey = "messages.showLinkPreviews"

    private let defaults: UserDefaults
    private(set) var showsPreviews: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showsPreviews = defaults.bool(forKey: Self.storageKey)
    }

    func setShowsPreviews(_ enabled: Bool) {
        showsPreviews = enabled
        HostSettingsSaveTiming.measure { defaults.set(enabled, forKey: Self.storageKey) }
    }
}
