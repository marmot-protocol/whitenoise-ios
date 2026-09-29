import Foundation
import MarmotKit

nonisolated enum MissingKeyPackageInvitationPresentation {
    static func accountIdHex(for error: Error) -> String? {
        guard case .MissingKeyPackage(let account) = error as? MarmotKitError else { return nil }
        return account
    }

    static func message(accountIdHex: String, knownName: String?) -> String {
        let resolved = IdentityPresentation.resolve(accountIdHex: accountIdHex, knownName: knownName)
        guard resolved.source == .name else {
            return L10n.string("This user isn't on White Noise yet.")
        }
        return L10n.formatted("%@ isn't on White Noise yet.", resolved.text)
    }
}
