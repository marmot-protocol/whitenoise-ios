import Foundation
import MarmotKit

nonisolated enum MissingKeyPackageInvitationPresentation {
    struct Recipient: Equatable {
        let accountIdHex: String
        let reason: MissingKeyPackageReasonFfi
    }

    static func recipient(for error: Error) -> Recipient? {
        guard case .MissingKeyPackage(let account, let reason) = error as? MarmotKitError else { return nil }
        return Recipient(accountIdHex: account, reason: reason)
    }

    static func message(for recipient: Recipient, knownName: String?) -> String {
        message(accountIdHex: recipient.accountIdHex, knownName: knownName, reason: recipient.reason)
    }

    /// `obsoleteOnly` recipients have only outdated invitation keys: they are
    /// reachable once they update, so the copy asks for that instead of an install.
    static func message(
        accountIdHex: String, knownName: String?, reason: MissingKeyPackageReasonFfi = .notFound
    ) -> String {
        let resolved = IdentityPresentation.resolve(accountIdHex: accountIdHex, knownName: knownName)
        let named = resolved.source == .name
        switch reason {
        case .notFound:
            return named
                ? L10n.formatted("%@ isn't on White Noise yet.", resolved.text)
                : L10n.string("This user isn't on White Noise yet.")
        case .obsoleteOnly:
            return named
                ? L10n.formatted("%@ needs to update their app before they can be invited.", resolved.text)
                : L10n.string("This user needs to update their app before they can be invited.")
        }
    }
}
