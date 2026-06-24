import Foundation
import Testing
@testable import whitenoise_ios
import MarmotKit

struct IdentityKeyExportPresentationTests {
    @Test func mapsEmptyPassphraseError() {
        let message = IdentityKeyExportPresentation.errorMessage(
            for: MarmotKitError.EmptyPassphrase
        )
        #expect(message == L10n.string("Enter a passphrase."))
    }

    @Test func mapsSecretNotFoundError() {
        let message = IdentityKeyExportPresentation.errorMessage(
            for: MarmotKitError.SecretNotFound(details: "missing")
        )
        #expect(message == L10n.string("This account cannot export a private key."))
    }

    @Test func mapsEncryptionFailedError() {
        let message = IdentityKeyExportPresentation.errorMessage(
            for: MarmotKitError.EncryptionFailed(details: "bad params")
        )
        #expect(message == L10n.formatted("Encrypted export failed: %@", "bad params"))
    }
}
