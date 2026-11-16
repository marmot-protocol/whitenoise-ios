import Foundation
import MarmotKit

/// A create or invite that found no requested member available. MDK created
/// no group and published no commit; `skipped` says why for each account.
nonisolated struct GroupMembersUnavailableError: LocalizedError, Equatable {
    let skipped: [MemberResolutionOutcomeFfi]

    var errorDescription: String? {
        GroupMemberOutcomePresentation.message(for: skipped, knownName: { _ in nil })
    }
}

extension DetailedGroupCreationResultFfi {
    /// The created group. Throws when a nonempty request reached nobody.
    nonisolated func requireCreated() throws -> CreatedGroupFfi {
        guard let created else {
            throw GroupMembersUnavailableError(skipped: GroupMemberOutcomePresentation.skipped(memberOutcomes))
        }
        return created
    }
}

extension InviteMembersResultFfi {
    /// The invite's commit summary. Throws when no invited member was available.
    nonisolated func requireSummary() throws -> SendSummaryFfi {
        guard let summary else {
            throw GroupMembersUnavailableError(skipped: GroupMemberOutcomePresentation.skipped(memberOutcomes))
        }
        return summary
    }
}

/// Wording for the requested accounts a create or invite went ahead without.
/// `selected` means MDK found devices and an inbox route, not that the person joined.
nonisolated enum GroupMemberOutcomePresentation {
    struct Notice: Equatable {
        let title: String
        let message: String
    }

    /// Toasts stay readable: name this many people, then count the rest.
    static let maxListedNames = 3

    static func skipped(_ outcomes: [MemberResolutionOutcomeFfi]) -> [MemberResolutionOutcomeFfi] {
        outcomes.filter { $0.status != .selected }
    }

    static func selectedCount(_ outcomes: [MemberResolutionOutcomeFfi]) -> Int {
        outcomes.count { $0.status == .selected }
    }

    /// The warning shown after a create or invite that left some people out.
    static func notice(
        for skipped: [MemberResolutionOutcomeFfi], knownName: (String) -> String?
    ) -> Notice? {
        guard !skipped.isEmpty else { return nil }
        let title = skipped.count == 1
            ? L10n.string("Couldn't add this person")
            : L10n.plural("Couldn't add %lld people", Int64(skipped.count))
        return Notice(title: title, message: message(for: skipped, knownName: knownName))
    }

    static func message(
        for skipped: [MemberResolutionOutcomeFfi], knownName: (String) -> String?
    ) -> String {
        let listed = skipped.prefix(maxListedNames).map { outcome in
            message(accountIdHex: outcome.accountIdHex, status: outcome.status,
                    knownName: knownName(outcome.accountIdHex))
        }
        let remaining = skipped.count - listed.count
        guard remaining > 0 else { return listed.joined(separator: "\n") }
        return (listed + [L10n.plural("%lld more couldn't be added.", Int64(remaining))]).joined(separator: "\n")
    }

    static func message(accountIdHex: String, status: MemberResolutionStatusFfi, knownName: String?) -> String {
        switch status {
        case .selected, .missingKeyPackage:
            return MissingKeyPackageInvitationPresentation.message(
                accountIdHex: accountIdHex, knownName: knownName, reason: .notFound)
        case .obsoleteKeyPackage, .incompatibleKeyPackage:
            return MissingKeyPackageInvitationPresentation.message(
                accountIdHex: accountIdHex, knownName: knownName, reason: .obsoleteOnly)
        case .invalidKeyPackage:
            return named(accountIdHex, knownName).map {
                L10n.formatted("%@ hasn't published a compatible key package, so they can't be messaged yet.", $0)
            } ?? L10n.string("This person has no compatible invitation key available. Ask them to open White Noise and try again.")
        case .missingInboxRoute:
            return named(accountIdHex, knownName).map {
                L10n.formatted("%@’s message inbox has no relay White Noise can use.", $0)
            } ?? L10n.string("This person’s message inbox has no relay White Noise can use.")
        case .incomplete:
            return named(accountIdHex, knownName).map {
                L10n.formatted("Couldn't finish looking up %@ on relays. Check your connection and try again.", $0)
            } ?? L10n.string("Couldn't finish looking this person up on relays. Check your connection and try again.")
        }
    }

    private static func named(_ accountIdHex: String, _ knownName: String?) -> String? {
        let resolved = IdentityPresentation.resolve(accountIdHex: accountIdHex, knownName: knownName)
        return resolved.source == .name ? resolved.text : nil
    }
}
