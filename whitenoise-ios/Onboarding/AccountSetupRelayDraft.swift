import Foundation
import MarmotKit

nonisolated struct AccountSetupRelayDraft: Equatable {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var address = ""
        var reads = true
        var writes = true

        var normalizedAddress: String? {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.contains(where: \.isWhitespace) else { return nil }
            return AccountSetupInput.proposalRelays([trimmed])?.first
        }
    }

    struct Selection: Equatable {
        var reads: [String] = []
        var writes: [String] = []
    }

    enum ValidationError: Error, Equatable {
        case invalidAddress(UUID)
        case missingRole(UUID)
        case missingWriteRelay
        case missingInboxRelay
        case tooManyRelays
    }

    var entries: [Entry] = []

    init(proposal: OnboardingRepairProposalFfi? = nil) {
        guard let proposal else { return }
        for (addresses, isWrite) in [(proposal.readRelays, false), (proposal.writeRelays, true)] {
            for address in addresses {
                let normalized = AccountSetupInput.proposalRelays([address])?.first
                if let index = entries.firstIndex(where: {
                    normalized != nil ? $0.normalizedAddress == normalized : $0.address == address
                }) {
                    if isWrite { entries[index].writes = true } else { entries[index].reads = true }
                } else {
                    entries.append(Entry(address: address, reads: !isWrite, writes: isWrite))
                }
            }
        }
    }

    func selection(for step: OnboardingStepFfi = .relays) throws -> Selection {
        var selection = Selection()
        for entry in entries {
            guard let address = entry.normalizedAddress else { throw ValidationError.invalidAddress(entry.id) }
            if step == .inboxRelays {
                if !selection.reads.contains(address) { selection.reads.append(address) }
                continue
            }
            guard entry.reads || entry.writes else { throw ValidationError.missingRole(entry.id) }
            if entry.reads, !selection.reads.contains(address) { selection.reads.append(address) }
            if entry.writes, !selection.writes.contains(address) { selection.writes.append(address) }
        }
        if step == .inboxRelays {
            guard !selection.reads.isEmpty else { throw ValidationError.missingInboxRelay }
        } else {
            guard !selection.writes.isEmpty else { throw ValidationError.missingWriteRelay }
        }
        guard !AccountSetupInput.exceedsSelectionLimit(reads: selection.reads, writes: selection.writes) else {
            throw ValidationError.tooManyRelays
        }
        return selection
    }
}
