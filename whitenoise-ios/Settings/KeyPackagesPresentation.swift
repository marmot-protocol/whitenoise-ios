import Foundation
import MarmotKit

struct KeyPackagesPresentation {
    struct CurrentPackage {
        let identifier: String
        let publishedAt: UInt64?
        let bytes: UInt64?
    }

    var current: CurrentPackage?
    var otherRelayPackages: [AccountKeyPackageFfi] = []

    static func ownershipLabel(_ state: AccountKeyPackageLocalStateFfi) -> String {
        switch state {
        case .notLocal: L10n.string("Observed on relays")
        case .current: L10n.string("Current on this device")
        case .pendingReplacement: L10n.string("Pending replacement on this device")
        case .retainedPrivateMaterial: L10n.string("Retained on this device")
        case .otherOwned: L10n.string("Owned by this device")
        }
    }

    init() {}

    init(inventory: [AccountKeyPackageInventoryEntryFfi], status: KeyPackageMaintenanceStatusFfi? = nil) {
        let current = inventory.first { $0.localState == .current }?.record
        self.init(packages: inventory.map(\.record),
                  currentReference: current?.keyPackageRefHex ?? status?.currentKeyPackageRefHex,
                  currentEventID: current?.eventIdHex ?? status?.authoredEventIdHex,
                  publishedAt: current?.publishedAt ?? status?.authoredEventCreatedAt)
    }

    init(packages: [AccountKeyPackageFfi], status: KeyPackageMaintenanceStatusFfi?) {
        self.init(
            packages: packages,
            currentReference: status?.currentKeyPackageRefHex,
            currentEventID: status?.authoredEventIdHex,
            publishedAt: status?.authoredEventCreatedAt
        )
    }

    init(
        packages: [AccountKeyPackageFfi],
        currentReference: String?,
        currentEventID: String?,
        publishedAt: UInt64? = nil
    ) {
        let reference = currentReference.flatMap { $0.isEmpty ? nil : $0 }
        let eventID = currentEventID.flatMap { $0.isEmpty ? nil : $0 }
        let sorted = packages.sorted {
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
            return $0.eventIdHex < $1.eventIdHex
        }
        if let reference {
            // The lifecycle identifies current material; relay timestamps cannot elect it.
            let record = sorted.first {
                $0.keyPackageRefHex == reference && (eventID == nil || $0.eventIdHex == eventID)
            }
            current = CurrentPackage(
                identifier: eventID ?? record?.eventIdHex ?? reference,
                publishedAt: publishedAt ?? record?.publishedAt,
                bytes: record?.keyPackageBytes
            )
        }
        var seenEvents = Set<String>()
        otherRelayPackages = sorted.filter {
            $0.relay && $0.keyPackageRefHex != reference && $0.eventIdHex != eventID
                && seenEvents.insert($0.eventIdHex).inserted
        }
    }
}
