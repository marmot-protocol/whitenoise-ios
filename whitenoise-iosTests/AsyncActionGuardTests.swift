import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct AsyncActionGuardTests {
    @Test func identityExportsReturnWhileExportIsAlreadyInFlight() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let model = IdentityViewModel()

        model.exportInFlight = true
        await model.exportRawNsec(using: appState)

        #expect(model.exportInFlight)
        #expect(model.exportError == nil)
        #expect(model.exportShareText == nil)

        await model.exportEncryptedNsec(passphrase: "passphrase", using: appState)

        #expect(model.exportInFlight)
        #expect(model.exportError == nil)
        #expect(model.exportShareText == nil)
    }

    @Test func privacyAuditToggleReturnsWhileSaveIsAlreadyInFlight() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let model = PrivacySecuritySettingsViewModel()
        let current = PrivacyAuditSettingsProjection(enabled: false)

        model.auditSettings = current
        model.auditSaving = true

        await model.setAuditEnabled(true, using: appState)

        #expect(model.auditSaving)
        #expect(model.auditSettings == current)
        #expect(model.auditErrorMessage == nil)
    }

    @Test func auditDeleteReturnsWhileDeleteIsAlreadyInFlight() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let model = PrivacySecuritySettingsViewModel()
        let row = AuditFileRow(
            fileName: "audit.jsonl",
            detailText: "1 KB - account",
            path: "/tmp/audit.jsonl"
        )

        model.auditFileRows = [row]
        model.auditDeleting = true

        await model.deleteAllAuditLogs(using: appState)

        #expect(model.auditDeleting)
        #expect(model.auditFileRows == [row])
        #expect(model.auditErrorMessage == nil)
    }
}
