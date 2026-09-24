import Foundation
import Observation

@MainActor
@Observable
final class ProfileAddressVerificationModel {
    private var hex: String?
    private(set) var verifiedNip05: String?
    private var completedNip05Verification: String?
    private var verificationGeneration: UInt64 = 0

    func applyResolvedAccount(_ resolvedHex: String?) {
        guard hex != resolvedHex else { return }
        hex = resolvedHex
        verifiedNip05 = nil
        completedNip05Verification = nil
        verificationGeneration &+= 1
    }

    /// Memoize completed lookups per address. Cancelled or failed requests
    /// remain retryable, and only the latest identity/address can earn a badge.
    func verifyDeclaredNip05(
        _ declared: String?,
        transport: Nip05Resolver.Transport = Nip05Resolver.pinnedTransport
    ) async {
        guard let hex, let declared = ContentSanitizer.profileAddress(declared) else {
            verificationGeneration &+= 1
            verifiedNip05 = nil
            completedNip05Verification = nil
            return
        }
        guard completedNip05Verification != declared else { return }
        verificationGeneration &+= 1
        let generation = verificationGeneration
        let verifyingHex = hex
        verifiedNip05 = nil
        completedNip05Verification = nil
        let verification = await Nip05Resolver.verification(
            declaredAddress: declared,
            accountIdHex: verifyingHex,
            transport: transport
        )
        guard !Task.isCancelled,
              generation == verificationGeneration,
              self.hex == verifyingHex
        else { return }
        switch verification {
        case .verified:
            verifiedNip05 = declared
            completedNip05Verification = declared
        case .mismatch:
            completedNip05Verification = declared
        case .lookupFailed:
            break
        }
    }
}
