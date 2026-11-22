import Foundation
import MarmotKit

/// Where an imported timeline row came from: another of this account's devices
/// (chat history brought by a link) or a backup restore.
nonisolated enum HistoryImportOrigin: Equatable {
    case device(slotIdHex: String, label: String)
    case backup

    init?(importedFrom: HistoryImportSourceFfi?, provenance: HistoryImportProvenanceFfi?) {
        switch provenance {
        case .backup: self = .backup
        case .device(let slotIdHex): self = .device(slotIdHex: slotIdHex, label: importedFrom?.deviceLabel ?? "")
        case nil:
            guard let importedFrom else { return nil }
            self = .device(slotIdHex: importedFrom.deviceSlotIdHex, label: importedFrom.deviceLabel)
        }
    }
}

/// Where the conversation marks a change from imported history to live
/// messages: above the first live message that follows imported ones.
nonisolated enum HistoryImportBoundaryProjection {
    static func boundaries(
        for timeline: [TimelineItem],
        origins: [String: HistoryImportOrigin]
    ) -> [String: HistoryImportOrigin] {
        var result: [String: HistoryImportOrigin] = [:]
        var previous: HistoryImportOrigin?
        for item in timeline {
            guard case .message(let record, _) = item.kind else { continue }
            let origin = record.messageIdHex.isEmpty ? nil : origins[record.messageIdHex]
            if origin == nil, let previous { result[item.id] = previous }
            previous = origin
        }
        return result
    }
}

nonisolated enum HistoryImportPresentation {
    /// `deviceName` is the device's current name when this device lists it.
    static func dividerText(_ origin: HistoryImportOrigin, deviceName: String?) -> String {
        switch origin {
        case .backup:
            return L10n.string("Messages above were restored from a backup")
        case .device(_, let label):
            let name = [deviceName, label]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return name.map { L10n.formatted("Messages above came from %@", $0) }
                ?? L10n.string("Messages above came from another device")
        }
    }

    /// The notice while a chat's history is still arriving, or nil once it's
    /// imported. MDK doesn't say which device is sending it until it arrives.
    static func arrivingNotice(_ state: ChatHistoryImportStateFfi?) -> String? {
        guard case .receiving(let retrying) = state else { return nil }
        return retrying
            ? L10n.string("Still trying to bring earlier messages from your other device…")
            : L10n.string("Bringing earlier messages from your other device…")
    }
}
