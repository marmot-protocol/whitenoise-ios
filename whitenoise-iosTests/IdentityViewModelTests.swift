import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

/// A private key is read only for the profile and screen the user confirmed
/// on, and a key that arrives after either changed is never shown or shared.
@MainActor
struct IdentityViewModelTests {
    @Test func aConfirmedRevealShowsTheConfirmingProfilesKey() async throws {
        let keys = IdentityKeysStub()
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")

        model.requestRawKey(.reveal, using: appState)
        let request = try #require(model.rawKeyRequest)
        await model.performRawKeyRequest(request, using: appState)

        #expect(keys.reveals == ["account"])
        #expect(model.revealedNsec == "nsec-account")
        #expect(!model.exportInFlight)
        #expect(model.rawActionInFlight == nil)

        model.hidePrivateKey()
        #expect(model.revealedNsec == nil)
    }

    @Test func aRequestConfirmedAfterSwitchingProfilesReadsNoKey() async throws {
        let keys = IdentityKeysStub()
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")
        model.requestRawKey(.export, using: appState)
        let request = try #require(model.rawKeyRequest)

        appState.activeAccountRef = "other"
        await model.performRawKeyRequest(request, using: appState)

        #expect(keys.reveals.isEmpty)
        #expect(model.exportShareText == nil)
    }

    enum Change: CaseIterable { case profileSwitched, screenClosed }

    @Test(arguments: Change.allCases)
    func aKeyArrivingAfterAChangeIsDiscarded(_ change: Change) async throws {
        let keys = IdentityKeysStub()
        let gate = AsyncTestCheckpoint()
        keys.revealGate = gate
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")
        model.requestRawKey(.reveal, using: appState)
        let request = try #require(model.rawKeyRequest)

        let reveal = Task { await model.performRawKeyRequest(request, using: appState) }
        await gate.waitUntilPaused()
        #expect(model.rawActionInFlight == .reveal)
        switch change {
        case .profileSwitched: appState.activeAccountRef = "other"
        case .screenClosed: model.clearPresentation()
        }
        await gate.release()
        await reveal.value

        #expect(model.revealedNsec == nil)
        #expect(model.exportError == nil)
        if change == .screenClosed {
            // The closed screen's confirmation can't be replayed on the next one.
            await model.performRawKeyRequest(request, using: appState)
            #expect(keys.reveals.count == 1)
            #expect(!model.exportInFlight)
        }
    }

    @Test func oneKeyActionRunsAtATime() async throws {
        let keys = IdentityKeysStub()
        let gate = AsyncTestCheckpoint()
        keys.revealGate = gate
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")
        model.requestRawKey(.reveal, using: appState)
        let request = try #require(model.rawKeyRequest)

        let reveal = Task { await model.performRawKeyRequest(request, using: appState) }
        await gate.waitUntilPaused()
        await model.performRawKeyRequest(request, using: appState)
        await model.exportEncryptedNsec(passphrase: "secret", using: appState)
        await gate.release()
        await reveal.value

        #expect(keys.reveals.count == 1)
        #expect(keys.encryptedExports.isEmpty)
    }

    @Test func aFailedReadShowsWhyAndKeepsTheKeyHidden() async throws {
        let keys = IdentityKeysStub()
        keys.revealError = MarmotKitError.SecretNotFound(details: "missing")
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")
        model.requestRawKey(.reveal, using: appState)

        await model.performRawKeyRequest(try #require(model.rawKeyRequest), using: appState)

        #expect(model.revealedNsec == nil)
        #expect(model.exportError == L10n.string("This account cannot export a private key."))
        #expect(!model.exportInFlight)
    }

    /// Sharing waits for the password sheet to finish closing.
    @Test func anEncryptedBackupIsSharedOnceThePasswordSheetCloses() async {
        let keys = IdentityKeysStub()
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")
        model.showEncryptedExportSheet = true

        await model.exportEncryptedNsec(passphrase: "secret", using: appState)

        #expect(keys.encryptedExports == ["account:secret"])
        #expect(!model.showEncryptedExportSheet)
        #expect(model.exportShareText == nil)
        model.encryptedSheetDismissed()
        #expect(model.exportShareText == "ncryptsec-account")
    }

    @Test func aFailedEncryptedBackupKeepsItsErrorInTheSheetUntilItCloses() async {
        let keys = IdentityKeysStub()
        keys.exportError = MarmotKitError.EmptyPassphrase
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")
        model.showEncryptedExportSheet = true

        await model.exportEncryptedNsec(passphrase: "", using: appState)

        #expect(model.showEncryptedExportSheet)
        #expect(model.exportError == L10n.string("Enter a passphrase."))
        model.showEncryptedExportSheet = false
        model.encryptedSheetDismissed()
        #expect(model.exportError == nil)
        #expect(model.exportShareText == nil)
    }

    @Test func anEncryptedBackupFinishingAfterAProfileSwitchIsNotShared() async {
        let keys = IdentityKeysStub()
        let gate = AsyncTestCheckpoint()
        keys.exportGate = gate
        let model = IdentityViewModel(keys: keys.calls)
        let appState = Self.appState(account: "account")
        model.showEncryptedExportSheet = true

        let export = Task { await model.exportEncryptedNsec(passphrase: "secret", using: appState) }
        await gate.waitUntilPaused()
        appState.activeAccountRef = "other"
        await gate.release()
        await export.value
        model.encryptedSheetDismissed()

        #expect(model.exportShareText == nil)
        #expect(model.exportError == nil)
    }

    private static func appState(account: String) -> AppState {
        let appState = AppState.test()
        appState.activeAccountRef = account
        return appState
    }
}

/// Answers key reads with a value naming the account, recording each read.
@MainActor
private final class IdentityKeysStub {
    var revealError: Error?
    var exportError: Error?
    var revealGate: AsyncTestCheckpoint?
    var exportGate: AsyncTestCheckpoint?
    private(set) var reveals: [String] = []
    private(set) var encryptedExports: [String] = []

    var calls: IdentityKeyCalls {
        IdentityKeyCalls(
            revealNsec: { _, accountRef in
                self.reveals.append(accountRef)
                await self.revealGate?.pause()
                if let error = self.revealError { throw error }
                return "nsec-\(accountRef)"
            },
            exportEncryptedSecretKey: { _, accountRef, passphrase in
                self.encryptedExports.append("\(accountRef):\(passphrase)")
                await self.exportGate?.pause()
                if let error = self.exportError { throw error }
                return "ncryptsec-\(accountRef)"
            }
        )
    }
}
