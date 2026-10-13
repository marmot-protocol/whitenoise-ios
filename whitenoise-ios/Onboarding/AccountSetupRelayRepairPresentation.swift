import Foundation
import MarmotKit

/// Display model for MDK's typed relay-list preview. Rows follow MDK's ordered
/// diff; approval also requires the diff to account for every published tag.
nonisolated struct AccountSetupRelayRepairPresentation: Equatable {
    enum Change: Equatable { case added, removed, kept }
    enum Use: Equatable { case readAndWrite, read, write, inbox, other }
    enum EditOutcome: Equatable { case review, unchanged, failed }

    struct Row: Identifiable, Equatable {
        let id: Int
        let change: Change
        let use: Use
        /// Sanitized, bounded display text. Nil when the tag has no displayable text.
        let text: String?
        let host: String?
        let restores: OnboardingRelayCapabilityFfi
        /// A relay address this proposal would publish that fails the app's validator.
        let isInvalidPublishedAddress: Bool
    }

    let mode: OnboardingRelayRepairModeFfi
    let rows: [Row]
    let beforeTags: [OnboardingRelayTagFfi]
    let afterTags: [OnboardingRelayTagFfi]
    private let accountsForPublishedTags: Bool
    private let contentUnchanged: Bool

    init?(proposal: OnboardingRepairProposalFfi?, step: OnboardingStepFfi) {
        guard let proposal, proposal.step == step, let repair = proposal.relayRepair else { return nil }
        mode = repair.mode
        beforeTags = repair.beforeTags
        afterTags = repair.afterTags
        contentUnchanged = repair.originalContent == repair.proposedContent
        rows = repair.changes.enumerated().map { index, change in
            let kind: Change = switch change.disposition {
            case .added: .added
            case .removed: .removed
            case .retained: .kept
            }
            let use = Self.use(change.role)
            let published = kind != .removed && use != .other
            return Row(
                id: index, change: kind, use: use,
                text: Self.displayText(endpoint: change.endpoint, fields: change.fields),
                host: change.endpoint.flatMap { AccountSetupInput.proposalRelays([$0])?.first }
                    .flatMap { URL(string: $0)?.host },
                restores: kind == .added ? change.restores : .none,
                isInvalidPublishedAddress: published && !Self.isValidAddress(change.endpoint)
            )
        }
        var published: Set<Int> = []
        var accounted = true
        for change in repair.changes {
            switch (change.disposition, change.afterIndex) {
            case (.removed, nil): continue
            case (.removed, _), (_, nil): accounted = false
            case (_, let index?):
                let position = Int(clamping: index)
                if position >= repair.afterTags.count || repair.afterTags[position].fields != change.fields
                    || !published.insert(position).inserted {
                    accounted = false
                }
            }
        }
        accountsForPublishedTags = accounted && published.count == repair.afterTags.count
    }

    var isManualReview: Bool { mode == .manualReview }
    var added: [Row] { rows.filter { $0.change == .added } }
    var removed: [Row] { rows.filter { $0.change == .removed } }
    var kept: [Row] { rows.filter { $0.change == .kept } }

    /// Every relay declaration left in the published list passes the app's validator.
    var publishesOnlyValidAddresses: Bool {
        afterTags.allSatisfy { Self.use($0.role) == .other || Self.isValidAddress($0.endpoint) }
    }

    /// Manual review prefills the editor from the original tags; otherwise from the preview.
    var editorDraft: AccountSetupRelayDraft {
        AccountSetupRelayDraft(tags: isManualReview ? beforeTags : afterTags)
    }

    /// A default-relay replacement is a no-op when the current list already declares exactly the defaults.
    /// The replacement declares the defaults as both read and write relays on
    /// the Relay step, and as inbox relays on the Inbox step, so roles count too.
    func offersDefaultReplacement(defaults: [String], step: OnboardingStepFfi) -> Bool {
        let normalizedDefaults = Set(AccountSetupInput.proposalRelays(defaults) ?? defaults)
        func addresses(_ uses: Set<Use>) -> Set<String> {
            Set(beforeTags.compactMap { tag -> String? in
                guard uses.contains(Self.use(tag.role)), let endpoint = tag.endpoint else { return nil }
                return AccountSetupInput.proposalRelays([endpoint])?.first ?? endpoint
            })
        }
        guard step == .relays else {
            return addresses([.readAndWrite, .read, .write, .inbox]) != normalizedDefaults
        }
        return addresses([.readAndWrite, .read]) != normalizedDefaults
            || addresses([.readAndWrite, .write]) != normalizedDefaults
    }

    /// The diff is a real change that accounts for every published tag, keeps the
    /// content, and publishes only valid addresses. Manual review never qualifies.
    var isApprovable: Bool {
        !isManualReview && publishesOnlyValidAddresses && contentUnchanged && accountsForPublishedTags
    }

    /// How an explicit relay edit landed: ready for review, unchanged (manual review), or failed.
    static func editOutcome(_ snapshot: OnboardingSnapshotFfi, step: OnboardingStepFfi, errorMessage: String?) -> EditOutcome {
        guard errorMessage == nil, let proposal = snapshot.proposal, proposal.step == step,
              let actions = snapshot.steps.first(where: { $0.step == step })?.actions else { return .failed }
        if proposal.relayRepair?.mode == .manualReview, actions.contains(.editRelays) { return .unchanged }
        return actions.contains(.approveRepair) ? .review : .failed
    }

    static func use(_ role: OnboardingRelayTagRoleFfi) -> Use {
        switch role {
        case .unmarked: .readAndWrite
        case .read: .read
        case .write: .write
        case .inbox: .inbox
        case .other: .other
        }
    }

    private static func isValidAddress(_ endpoint: String?) -> Bool {
        guard let endpoint else { return false }
        return AccountSetupInput.proposalRelays([endpoint]) != nil
    }

    private static func displayText(endpoint: String?, fields: [String]) -> String? {
        if let endpoint, let line = ContentSanitizer.relayDisplayLine(endpoint, maxLength: 512) { return line }
        let bounded = fields.prefix(4).map { String($0.prefix(128)) }.joined(separator: " ")
        return ContentSanitizer.relayDisplayLine(bounded, maxLength: 512)
    }
}
