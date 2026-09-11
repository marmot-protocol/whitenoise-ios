import Foundation
import MarmotKit

enum IdentityKeyExportPresentation {
    static func errorMessage(for error: Error) -> String {
        guard let error = error as? MarmotKitError else {
            return UserFacingError.message(for: error)
        }
        switch error {
        case .EmptyPassphrase:
            return L10n.string("Enter a passphrase.")
        case .SecretNotFound:
            return L10n.string("This account cannot export a private key.")
        case .KeystoreUnavailable:
            return L10n.string("The account keystore is unavailable right now.")
        case .EncryptionFailed:
            return L10n.formatted("Encrypted export failed: %@", UserFacingError.message(for: error))
        default:
            return UserFacingError.message(for: error)
        }
    }
}
