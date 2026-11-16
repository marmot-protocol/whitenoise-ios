import Foundation
@preconcurrency import MarmotKit

/// Per-device developer choice to open Marmot with MDK's experimental device
/// groups (multi-device linking). Lives in the shared App Group suite so the
/// main app and the Notification Service Extension open the root the same way:
/// MDK refuses to open an account that holds or is joining a device group from
/// an ordinary constructor.
nonisolated enum ExperimentalDeviceGroupsPreference {
    static let storageKey = "marmot.experimentalDeviceGroups"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    /// An unresolvable suite reads as off: the ordinary constructor.
    static func isEnabled() -> Bool {
        guard let defaults else { return false }
        return isEnabled(defaults: defaults)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}

/// Opens a Marmot root, choosing the experimental device-group constructor
/// when requested. A library built without `dev-device-groups` refuses that
/// constructor before touching the root, so it falls back to the ordinary one.
nonisolated enum MarmotRuntimeOpener {
    struct Opened {
        let marmot: Marmot
        /// True only when the experimental constructor accepted the root.
        let deviceGroupsEnabled: Bool
    }

    static func open(
        rootPath: String,
        relayUrls: [String],
        options: MarmotOptions,
        deviceGroupsRequested: Bool
    ) throws -> Opened {
        if deviceGroupsRequested {
            do {
                let marmot = try Marmot.newWithExperimentalDeviceGroups(
                    rootPath: rootPath, relayUrls: relayUrls, options: options
                )
                return Opened(marmot: marmot, deviceGroupsEnabled: true)
            } catch where isCapabilityUnavailable(error) {
                // Fall through to the ordinary constructor.
            }
        }
        let marmot = try Marmot.newWithConfiguration(rootPath: rootPath, relayUrls: relayUrls, options: options)
        return Opened(marmot: marmot, deviceGroupsEnabled: false)
    }

    /// MDK's refusal from a library compiled without `dev-device-groups`.
    static func isCapabilityUnavailable(_ error: Error) -> Bool {
        guard let error = error as? MarmotKitError, case .Runtime(let details) = error else { return false }
        return details.contains("experimental_device_groups_unavailable")
    }
}

