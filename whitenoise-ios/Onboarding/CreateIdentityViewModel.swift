import Foundation
import MarmotKit
import OSLog
import UIKit

@MainActor
protocol CreateIdentityServicing: AnyObject {
    func listIdentityAccounts() async throws -> [AccountSummaryFfi]
    func loadIdentityProfile(accountID: String) async throws -> UserProfileMetadataFfi?
    func removeUnfinishedSignUpAccount(_ account: AccountSummaryFfi) async throws
    func suggestedProfileName() async throws -> String
    func createIdentityForProfileSetup() async throws -> IdentityCreationResultFfi
    func waitForIdentityProfileSetup(accountRef: String, retry: Bool) async throws
    func uploadOnboardingAvatar(
        accountRef: String,
        draft: GroupImageUploadDraft
    ) async throws -> String
    func publishOnboardingProfile(
        accountRef: String,
        profile: UserProfileMetadataFfi
    ) async throws
    func completeIdentityProfileSetup(_ summary: AccountSummaryFfi) async
}

extension AppState: CreateIdentityServicing {
    func listIdentityAccounts() async throws -> [AccountSummaryFfi] {
        try await currentMarmotClient().listAccounts()
    }

    func loadIdentityProfile(accountID: String) async throws -> UserProfileMetadataFfi? {
        try await currentMarmotClient().userProfileForEditing(accountIdHex: accountID)
    }

    func suggestedProfileName() async throws -> String {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        return await lease.client.randomProfilePseudonym()
    }

    func uploadOnboardingAvatar(
        accountRef: String,
        draft: GroupImageUploadDraft
    ) async throws -> String {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let url = try await lease.client.uploadProfileImage(
            accountRef: accountRef,
            data: draft.data,
            mediaType: draft.mediaType,
            blossomServer: nil
        )
        guard let normalized = ContentSanitizer.imageURL(url)?.absoluteString else {
            throw ProfileImageUploadError.invalidReturnedURL
        }
        return normalized
    }

    func publishOnboardingProfile(
        accountRef: String,
        profile: UserProfileMetadataFfi
    ) async throws {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        _ = try await lease.client.publishUserProfileUsingAccountRelays(
            accountRef: accountRef,
            profile: profile
        )
    }
}

nonisolated struct OnboardingProfileMetadataDraft: Equatable {
    var displayName: String
    var about: String
    var uploadedPictureURL: String?

    var hasEdits: Bool {
        normalizedDisplayName != nil
            || normalizedAbout != nil
            || uploadedPictureURL != nil
    }

    func merging(with existing: UserProfileMetadataFfi?) -> UserProfileMetadataFfi? {
        guard hasEdits else { return nil }
        let editedName = normalizedDisplayName
        return UserProfileMetadataFfi(
            // The single onboarding Name field is authoritative for both
            // Nostr spellings whenever the user changes it.
            name: editedName ?? existing?.name,
            displayName: editedName ?? existing?.displayName,
            about: normalizedAbout ?? existing?.about,
            picture: uploadedPictureURL ?? existing?.picture,
            banner: existing?.banner,
            nip05: existing?.nip05,
            lud16: existing?.lud16
        )
    }

    private var normalizedDisplayName: String? {
        ContentSanitizer.displayName(displayName)
    }

    private var normalizedAbout: String? {
        ContentSanitizer.multilineText(about)
    }
}

/// Screen store for `CreateIdentityView`: owns the in-flight/error state and the
/// create/profile action, including the identity returned before optional
/// metadata is published. Keeping that identity in the model makes profile
/// retries idempotent: they never call create a second time.
@MainActor
@Observable
final class CreateIdentityViewModel {
    enum Phase: Equatable {
        case editing
        case creating
        case creationFailed
        case finishingSetup
        case setupFailed
        case uploadingPhoto
        case savingProfile
        case profileSaveFailed
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "sign-up"
    )

    enum Failure: Equatable {
        case creation, setup, photoUpload, profile, draftStorage, restore, restart
        var message: String {
            switch self {
            case .restart: L10n.string("Couldn’t restart sign-up. Please try again to finish clearing your progress.")
            case .creation: L10n.string("Couldn’t create your account. Please try again.")
            case .setup: L10n.string("Couldn’t finish setting up your account. Check your connection and try again.")
            case .photoUpload: L10n.string("Couldn’t upload your photo. Please try again or choose another photo.")
            case .profile: L10n.string("Couldn’t save your profile details. Please try again.")
            case .draftStorage: L10n.string("Couldn’t save your sign-up progress on this device. Free up some space and try again.")
            case .restore: L10n.string("Couldn’t restore your unfinished sign-up. Please try again.")
            }
        }
    }

    var failure: Failure?
    private(set) var isFinished = false
    private(set) var isResetting = false
    private var isSavingAvatar = false
    private(set) var isRestorationBlocked = false
    var isResetPending: Bool { draft.stage == .resetting }
    private(set) var draft = SignUpDraft()
    private var draftStore: SignUpDraftStore?
    private var didConfigurePersistence = false
    @ObservationIgnored private var draftPersistenceTask: Task<Void, Never>?

    var displayName = ""
    var about = ""
    private(set) var avatarDraft: GroupImageUploadDraft?
    private(set) var phase: Phase = .editing

    private(set) var createdIdentity: AccountSummaryFfi?
    private var existingProfile: UserProfileMetadataFfi?
    private var hasSuggestedName = false
    private var isSuggestingName = false
    private var uploadedAvatarURL: String?

    var isSubmitting: Bool {
        phase == .creating || phase == .finishingSetup || phase == .uploadingPhoto || phase == .savingProfile
    }

    var isSavingProfile: Bool {
        phase == .savingProfile
    }

    var isBusy: Bool {
        isSubmitting || isResetting || isSavingAvatar
    }

    var allowsBackNavigation: Bool {
        !isBusy
    }

    func configurePersistence(
        store: SignUpDraftStore, restored: SignUpDraft? = nil,
        identity: AccountSummaryFfi? = nil, profile: UserProfileMetadataFfi? = nil
    ) async {
        guard !didConfigurePersistence else { return }
        didConfigurePersistence = true
        draftStore = store
        guard let restored, restored.requiresRecovery else { return }
        draft = restored
        displayName = restored.displayName
        about = restored.about
        uploadedAvatarURL = restored.uploadedPhotoURL
        createdIdentity = identity
        existingProfile = profile
        hasSuggestedName = true
        if let photo = restored.photo {
            let thumbnail = await Task.detached(priority: .utility) { UIImage(data: photo.data) }.value
            avatarDraft = GroupImageUploadDraft(data: photo.data, mediaType: photo.mediaType,
                                               sourceURL: nil, dim: photo.dim, thumbhash: photo.thumbhash, thumbnail: thumbnail)
        }
        phase = .editing
    }

    func configureRestorationFailure(store: SignUpDraftStore, restored: SignUpDraft?) async {
        await configurePersistence(store: store, restored: restored)
        isRestorationBlocked = true
        failure = .restore
    }

    func discardUnrestorableDraft() async -> Bool {
        guard isRestorationBlocked, !isBusy else { return false }
        isResetting = true
        defer { isResetting = false }
        do {
            // Discard only host form data. No account identity can be inferred here.
            try await draftStore?.discardUnrestorableDraft()
            draft = SignUpDraft()
            createdIdentity = nil
            existingProfile = nil
            displayName = ""
            about = ""
            avatarDraft = nil
            uploadedAvatarURL = nil
            hasSuggestedName = false
            isRestorationBlocked = false
            failure = nil
            phase = .editing
            return true
        } catch {
            failure = .restore
            return false
        }
    }

    @discardableResult
    func scheduleDraftPersistence(delay: Duration = .milliseconds(350)) -> Task<Void, Never>? {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        guard draft.requiresRecovery, !isRestorationBlocked, !isFinished, !isBusy else { return nil }
        draftPersistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            draftPersistenceTask = nil
            await persistDraft()
        }
        return draftPersistenceTask
    }

    func persistDraft() async {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        guard draftStore != nil, !isRestorationBlocked, !isFinished, !isBusy else { return }
        do { try await checkpoint() }
        catch { failure = .draftStorage }
    }

    private func invalidateCompletionAfterEdits() {
        let photo = avatarDraft.map { SignUpDraft.Photo(data: $0.data, mediaType: $0.mediaType, dim: $0.dim, thumbhash: $0.thumbhash) }
        if draft.stage == .completed || draft.stage == .publishing,
           draft.displayName != displayName || draft.about != about || draft.photo != photo || draft.uploadedPhotoURL != uploadedAvatarURL {
            draft.stage = createdIdentity == nil ? .editing : .setup
        }
    }

    private func checkpoint(_ stage: SignUpDraft.Stage? = nil) async throws {
        guard !isRestorationBlocked else { throw SignUpDraftStore.Failure.unreadable }
        invalidateCompletionAfterEdits()
        if let stage { draft.stage = stage }
        guard draft.requiresRecovery else { return }
        draft.displayName = displayName
        draft.about = about
        draft.photo = avatarDraft.map { .init(data: $0.data, mediaType: $0.mediaType, dim: $0.dim, thumbhash: $0.thumbhash) }
        draft.uploadedPhotoURL = uploadedAvatarURL
        if let createdIdentity {
            draft.accountRef = createdIdentity.label
            draft.accountID = createdIdentity.accountIdHex
        }
        draft.revision += 1
        do { try await draftStore?.save(draft) }
        catch { throw SignUpDraftStore.Failure.writeFailed }
    }

    func acceptPreparedAvatar(_ prepared: GroupImageUploadDraft?) async throws {
        try Task.checkCancellation()
        guard !isBusy, !isResetPending, !isRestorationBlocked, !isFinished else { throw CancellationError() }
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        isSavingAvatar = true
        defer { isSavingAvatar = false }
        let previous = avatarDraft
        let previousURL = uploadedAvatarURL
        let previousDraft = draft
        setAvatarDraft(prepared)
        do { try await checkpoint() }
        catch {
            avatarDraft = previous
            uploadedAvatarURL = previousURL
            draft = previousDraft
            throw CocoaError(.fileWriteUnknown)
        }
        if failure == .draftStorage { failure = nil }
        if prepared == nil, failure == .photoUpload {
            failure = nil
            phase = .editing
        }
    }

    func setAvatarDraft(_ draft: GroupImageUploadDraft?) {
        guard !isSubmitting else { return }
        avatarDraft = draft
        uploadedAvatarURL = nil
    }

    /// Prepare the form without starting account creation.
    func prepare(using service: CreateIdentityServicing) async {
        guard !Task.isCancelled, !isRestorationBlocked else { return }
        if isResetPending {
            // The persisted reset records consent; finish it before allowing another submission.
            guard failure != .restart, await startOver(using: service) else { return }
        }
        guard !hasSuggestedName, !isSuggestingName, phase == .editing,
              displayName.isEmpty else { return }
        isSuggestingName = true
        defer { isSuggestingName = false }
        guard let suggestion = try? await service.suggestedProfileName(),
              !Task.isCancelled, phase == .editing, displayName.isEmpty else { return }
        displayName = ContentSanitizer.displayName(suggestion) ?? ""
        hasSuggestedName = true
    }

    func submit(
        using service: CreateIdentityServicing,
        dismiss: () -> Void
    ) async {
        guard !isBusy, !isRestorationBlocked, !isResetPending, ContentSanitizer.displayName(displayName) != nil else { return }
        let performance = HostActionPerformance.begin()
        invalidateCompletionAfterEdits()
        let retry = createdIdentity != nil || draft.baselineAccountIDs != nil
        let publicationMayHaveCompleted = draft.stage == .publishing
        phase = retry ? .finishingSetup : .creating
        failure = nil
        do {
            try Task.checkCancellation()
            if !draft.requiresRecovery { try await checkpoint(.creating) }
            if createdIdentity == nil, draft.baselineAccountIDs != nil {
                let accounts = try await service.listIdentityAccounts()
                if let recovered = try draft.recoveredAccount(in: accounts) {
                    createdIdentity = recovered
                    existingProfile = try await service.loadIdentityProfile(accountID: recovered.accountIdHex)
                }
            }
            if createdIdentity == nil {
                phase = .creating
                if draft.baselineAccountIDs == nil {
                    draft.baselineAccountIDs = try await service.listIdentityAccounts().map(\.accountIdHex)
                }
                try await checkpoint(.creating)
                try Task.checkCancellation()
                let creation = try await service.createIdentityForProfileSetup()
                createdIdentity = creation.account
                existingProfile = creation.profile
            }
            guard let createdIdentity else { return }
            if draft.stage == .completed {
                try await finish(using: service, identity: createdIdentity, dismiss: dismiss)
                return
            }
            phase = .finishingSetup
            try await checkpoint(publicationMayHaveCompleted ? .publishing : .setup)
            try Task.checkCancellation()
            try await service.waitForIdentityProfileSetup(accountRef: createdIdentity.label, retry: retry)
            try Task.checkCancellation()
            if publicationMayHaveCompleted,
               let profile = try await service.loadIdentityProfile(accountID: createdIdentity.accountIdHex),
               draft.matchesPublishedProfile(profile) {
                try await finish(using: service, identity: createdIdentity, dismiss: dismiss)
                return
            }
            phase = .savingProfile
            try await savePendingProfile(for: createdIdentity, using: service)
            try Task.checkCancellation()
            try await finish(using: service, identity: createdIdentity, dismiss: dismiss)
            HostActionPerformance.record("identity_submit_to_ready", since: performance)
        } catch {
            HostActionPerformance.record("identity_submit_failed", since: performance)
            let stage = phase == .creating ? "creation" : phase == .finishingSetup ? "setup" : "profile"
            let category = Self.failureCategory(error)
            Self.log.error("Sign-up failed stage=\(stage, privacy: .public) category=\(category, privacy: .public)")
            if error as? SignUpDraftStore.Failure == .writeFailed {
                failure = .draftStorage
            } else if error is SignUpDraftStore.Failure {
                isRestorationBlocked = true
                failure = .restore
            } else {
                switch phase {
                case .creating: failure = .creation
                case .finishingSetup: failure = .setup
                case .uploadingPhoto: failure = .photoUpload
                default: failure = .profile
                }
            }
            phase = createdIdentity == nil ? .creationFailed : phase == .finishingSetup ? .setupFailed : .profileSaveFailed
            if Task.isCancelled {
                failure = nil
                phase = .editing
            } else {
                Haptics.error()
            }
        }
    }

    func startOver(using service: CreateIdentityServicing) async -> Bool {
        guard !isBusy, !isFinished, !isRestorationBlocked else { return false }
        isResetting = true
        failure = nil
        defer { isResetting = false }
        do {
            try await checkpoint(.resetting)
            let accounts = try await service.listIdentityAccounts()
            createdIdentity = try draft.recoveredAccount(in: accounts)
            try await checkpoint(.resetting)
            if let createdIdentity {
                try Task.checkCancellation()
                try await service.removeUnfinishedSignUpAccount(createdIdentity)
            }
            try await draftStore?.clear(id: draft.id)
            draft = SignUpDraft()
            createdIdentity = nil
            existingProfile = nil
            displayName = ""
            about = ""
            avatarDraft = nil
            uploadedAvatarURL = nil
            hasSuggestedName = false
            phase = .editing
            return true
        } catch {
            if let error = error as? SignUpDraftStore.Failure, error != .writeFailed {
                isRestorationBlocked = true
                failure = .restore
            } else {
                failure = Task.isCancelled ? nil : .restart
            }
            return false
        }
    }

    private func finish(
        using service: CreateIdentityServicing, identity: AccountSummaryFfi, dismiss: () -> Void
    ) async throws {
        try await checkpoint(.completed)
        isFinished = true
        await service.completeIdentityProfileSetup(identity)
        try? await draftStore?.clear(id: draft.id)
        Haptics.success()
        dismiss()
    }

    private static func failureCategory(_ error: Error) -> String {
        if error is CancellationError || Task.isCancelled { return "cancelled" }
        if let error = error as? IdentitySetupReadinessWaiter.Failure {
            return error == .timedOut ? "setup_timeout" : "setup_recovery_required"
        }
        if let error = error as? MarmotKitError {
            switch error {
            case .Publish: return "publication"
            case .Runtime, .RuntimeBusy, .RuntimeStopping: return "runtime"
            case .Io: return "io"
            case .StorageBusy, .StorageClosed: return "storage"
            default: return "sdk"
            }
        }
        return "other"
    }

    private func savePendingProfile(
        for identity: AccountSummaryFfi,
        using service: CreateIdentityServicing
    ) async throws {
        if let avatarDraft, uploadedAvatarURL == nil {
            phase = .uploadingPhoto
            try await checkpoint(.uploading)
            try Task.checkCancellation()
            uploadedAvatarURL = try await service.uploadOnboardingAvatar(
                accountRef: identity.label,
                draft: avatarDraft
            )
        }

        try Task.checkCancellation()
        phase = .savingProfile
        try await checkpoint(.publishing)
        try Task.checkCancellation()
        let name = ContentSanitizer.displayName(displayName)
        let profile = UserProfileMetadataFfi(
            name: name, displayName: name, about: ContentSanitizer.multilineText(about),
            picture: uploadedAvatarURL, banner: existingProfile?.banner,
            nip05: existingProfile?.nip05, lud16: existingProfile?.lud16
        )
        try await service.publishOnboardingProfile(
            accountRef: identity.label,
            profile: profile
        )
    }
}

@MainActor
enum IdentitySetupReadinessWaiter {
    enum Failure: Error { case timedOut, recoveryRequired }

    static func wait(
        timeout: Duration = .seconds(60),
        readiness: () async throws -> AccountSetupReadinessFfi
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let state = try await readiness()
            try Task.checkCancellation()
            switch state {
            case .networkReady: return
            case .recoveryRequired: throw Failure.recoveryRequired
            case .initializing, .localReady, .publishing: break
            }
            guard clock.now < deadline else { throw Failure.timedOut }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(250))))
        }
    }
}

enum ProfileImageDraftProcessor {
    static func prepare(
        data: Data,
        fileName: String?,
        typeIdentifier: String?,
        sourceURL: URL? = nil
    ) async throws -> GroupImageUploadDraft {
        guard !data.isEmpty, data.count <= MediaDraftProcessor.maxAttachmentBytes else {
            throw MediaDraftProcessor.Failure.attachmentTooLarge(data.count)
        }
        let attachment = try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else {
                throw MediaDraftProcessor.Failure.unsupportedImage
            }
            return try MediaDraftProcessor.attachment(
                from: image,
                fileName: fileName,
                quality: .standard
            )
        }.value
        return GroupImageUploadDraft(
            data: attachment.data,
            mediaType: attachment.mediaType,
            sourceURL: ContentSanitizer.imageURL(sourceURL?.absoluteString)?.absoluteString,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            thumbnail: attachment.thumbnail
        )
    }
}
