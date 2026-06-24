import Testing
import Foundation
@testable import darkmatter_ios

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

    /// #111 — signing out must drain stale push-sync work before it clears the
    /// departing account's registration, then let the remaining account schedule
    /// its own fresh sync.
    @Test func signOutDrainsNativePushRegistrationBeforeAccountCleanup() throws {
        let appStateSource = try sourceString("darkmatter-ios/Core/AppState.swift")
        let coordinatorSource = try sourceString("darkmatter-ios/Core/NotificationCoordinator.swift")
        let cleanupPattern =
            #"func signOut\(\) async \{[\s\S]*"# +
            #"await notificationCoordinator\.cancelNativePushRegistrationTask\(\)[\s\S]*"# +
            #"marmot\.clearPushRegistration\(accountRef: signingOut\)"#
        let reschedulePattern =
            #"func signOut\(\) async \{[\s\S]*"# +
            #"activeAccountRef = accounts\.first\?\.label[\s\S]*"# +
            #"if activeAccountRef == nil \{[\s\S]*phase = \.onboarding[\s\S]*"# +
            #"\} else \{[\s\S]*scheduleNativePushRegistrationIfEnabled\(\)"#
        // `cancelNativePushRegistrationTask` widened from `private` to internal
        // (Phase 2) so RuntimeLifecycle's partial-runtime release can drain it;
        // the body (capture, nil, cancel, await) is unchanged.
        let cancelHelperPattern =
            #"func cancelNativePushRegistrationTask\(\) async \{[\s\S]*"# +
            #"let task = nativePushRegistrationTask[\s\S]*"# +
            #"nativePushRegistrationTask = nil[\s\S]*"# +
            #"task\?\.cancel\(\)[\s\S]*await task\?\.value"#

        #expect(sourceContains(cleanupPattern, in: appStateSource))
        #expect(sourceContains(reschedulePattern, in: appStateSource))
        #expect(sourceContains(cancelHelperPattern, in: coordinatorSource))
    }

    /// #258 — scheduleNativePushRegistrationIfEnabled must drain the prior
    /// (cancelled) registration task before starting a fresh sync, otherwise a
    /// reschedule (e.g. on token arrival) mid per-account write can issue two
    /// concurrent upsertPushRegistration FFI calls. The new task must capture
    /// the previous task, cancel it, and `await` its value before invoking
    /// syncNativePushRegistrationIfEnabled() — mirroring the drain in
    /// cancelNativePushRegistrationTask().
    @Test func scheduleNativePushDrainsPriorTaskBeforeNewSync() throws {
        let source = try sourceString("darkmatter-ios/Core/NotificationCoordinator.swift")
        let drainPattern =
            #"func scheduleNativePushRegistrationIfEnabled\(host: NotificationCoordinatorHost\) \{[\s\S]*"# +
            #"let previousTask = nativePushRegistrationTask[\s\S]*"# +
            #"previousTask\?\.cancel\(\)[\s\S]*"# +
            #"nativePushRegistrationTask = Task \{ \[weak self, weak host\] in[\s\S]*"# +
            #"await previousTask\?\.value[\s\S]*"# +
            #"await self\.syncNativePushRegistrationIfEnabled\(host: host\)"#
        #expect(sourceContains(drainPattern, in: source))
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

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceContains(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private enum NativePushTestError: Error {
        case generic
    }
}
