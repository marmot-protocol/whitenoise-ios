import Testing
import Foundation
@testable import whitenoise_ios

struct SendDispatchAndCancellationTests {

    /// #49 — send() must confirm it has a view model before clearing the draft,
    /// otherwise a nil view model at dispatch time silently discards the message.
    @MainActor
    @Test func sendPreparationKeepsDraftWhenViewModelIsMissing() {
        var draft = "hello"
        var attachments: [MediaDraftAttachment] = []

        let payload = ConversationSendPreparation.prepare(
            draft: &draft,
            mediaDrafts: &attachments,
            viewModel: nil
        )

        #expect(payload == nil)
        #expect(draft == "hello")
        #expect(attachments.isEmpty)
    }

    /// #76 — push registration must treat CancellationError as a non-failure and
    /// not surface it as "Push registration failed".
    @Test func pushRegistrationIgnoresCancellation() {
        #expect(NativePushRegistrationErrorDisposition.disposition(for: CancellationError()) == .stopSync)
        #expect(NativePushRegistrationErrorDisposition.disposition(
            for: NotificationSettingsActionError.missingApnsToken
        ) == .stopSync)
        #expect(NativePushRegistrationErrorDisposition.disposition(for: NativePushTestError.generic) == .recordFailure)
    }

    /// #350 — native push registration reconciliation is best-effort and may
    /// run before the Keychain-backed runtime can be rebuilt. A transient
    /// runtime rebuild failure must skip this pass instead of trapping.
    @Test func nativePushEnabledAccountRefsSkipsWhenRuntimeRebuildFails() async {
        let accountRefs = await AppState.nativePushEnabledAccountRefs(accountRefs: ["account-a"]) {
            throw NativePushTestError.generic
        }

        #expect(accountRefs.isEmpty)
    }

    private enum NativePushTestError: Error {
        case generic
    }
}
