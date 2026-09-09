import MarmotKit

struct KeyPackagesPresentation {
    struct CurrentPackage {
        let identifier: String
        let publishedAt: UInt64?
        let bytes: UInt64?
    }

    var current: CurrentPackage?
    var otherRelayPackages: [AccountKeyPackageFfi] = []

    init() {}

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
