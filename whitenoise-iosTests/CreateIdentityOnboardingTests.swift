import MarmotKit
import Testing
import UIKit

@testable import whitenoise_ios

@MainActor
struct CreateIdentityOnboardingTests {
    @Test func onlySignInPrefersTheCompactSheetHeight() {
        #expect(!OnboardingSheetContent.welcome.prefersCompactHeight)
        #expect(OnboardingSheetContent.signIn.prefersCompactHeight)
        #expect(!OnboardingSheetContent.signUp.prefersCompactHeight)
    }

    @Test func blankDraftDoesNotReplaceEngineProfileDefaults() async {
        let service = CreateIdentityServiceStub()
        let model = CreateIdentityViewModel()
        var dismissed = false

        await model.prepare(using: service)

        #expect(model.displayName == "Engine Name")
        #expect(model.phase == .editing)
        await model.submit(using: service) {
            dismissed = true
        }

        #expect(service.createCount == 1)
        #expect(service.profileReadCount == 0)
        #expect(service.publishCount == 0)
        #expect(service.completeCount == 1)
        #expect(dismissed)
    }

    @Test func preparationDoesNotOverwriteAnEnteredDisplayName() async {
        let service = CreateIdentityServiceStub()
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"

        await model.prepare(using: service)

        #expect(model.displayName == "Alice")
        #expect(service.createCount == 1)
        #expect(service.profileReadCount == 0)
    }

    @Test func profileDraftRemainsEditableWhileIdentityCreationIsInFlight() async {
        let gate = IdentityCreationGate()
        let service = CreateIdentityServiceStub()
        service.beforeCreateReturn = {
            await gate.waitForRelease()
        }
        let model = CreateIdentityViewModel()

        let preparation = Task { await model.prepare(using: service) }
        await gate.waitUntilEntered()

        #expect(model.phase == .creating)
        #expect(!model.isSavingProfile)
        model.displayName = "Alice"
        model.about = "Written during setup"
        model.setAvatarDraft(Self.avatarDraft)

        await gate.release()
        await preparation.value

        #expect(model.displayName == "Alice")
        #expect(model.about == "Written during setup")
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(model.phase == .editing)
    }

    @Test func metadataMergePreservesUneditedFieldsAndSynchronizesEditedName() throws {
        let existing = UserProfileMetadataFfi(
            name: "engine-name",
            displayName: "Engine Name",
            about: "Engine about",
            picture: "https://example.com/old.jpg",
            banner: "https://example.com/banner.jpg",
            nip05: "engine@example.com",
            lud16: "engine@example.com"
        )
        let blank = OnboardingProfileMetadataDraft(
            displayName: " ",
            about: "",
            uploadedPictureURL: nil
        )
        #expect(blank.merging(with: existing) == nil)

        let edited = OnboardingProfileMetadataDraft(
            displayName: " Alice ",
            about: "Hello",
            uploadedPictureURL: "https://example.com/new.jpg"
        )
        let merged = try #require(edited.merging(with: existing))

        #expect(merged.name == "Alice")
        #expect(merged.displayName == "Alice")
        #expect(merged.about == "Hello")
        #expect(merged.picture == "https://example.com/new.jpg")
        #expect(merged.banner == existing.banner)
        #expect(merged.nip05 == existing.nip05)
        #expect(merged.lud16 == existing.lud16)
    }

    @Test func profileRetryNeverCreatesASecondIdentityOrUploadsAgain() async {
        let service = CreateIdentityServiceStub()
        service.publishFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.setAvatarDraft(Self.avatarDraft)
        var dismissCount = 0

        await model.submit(using: service) {
            dismissCount += 1
        }

        #expect(model.phase == .profileSaveFailed)
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(service.createCount == 1)
        #expect(service.uploadCount == 1)
        #expect(service.publishCount == 1)
        #expect(service.completeCount == 0)
        #expect(dismissCount == 0)

        await model.submit(using: service) {
            dismissCount += 1
        }

        #expect(service.createCount == 1)
        #expect(service.profileReadCount == 0)
        #expect(service.uploadCount == 1)
        #expect(service.publishCount == 2)
        #expect(service.completeCount == 1)
        #expect(dismissCount == 1)
    }

    @Test func creationFailureKeepsDraftAndAllowsARealCreationRetry() async {
        let service = CreateIdentityServiceStub()
        service.createFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.about = "Still here"
        model.setAvatarDraft(Self.avatarDraft)

        await model.submit(using: service) {}

        #expect(model.phase == .creationFailed)
        #expect(model.displayName == "Alice")
        #expect(model.about == "Still here")
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(service.createCount == 1)
        #expect(service.completeCount == 0)

        await model.submit(using: service) {}

        #expect(service.createCount == 2)
        #expect(service.completeCount == 1)
    }

    @Test func continuingAfterProfileFailureActivatesTheCreatedIdentity() async {
        let service = CreateIdentityServiceStub()
        service.publishFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        var dismissed = false

        await model.submit(using: service) {}
        #expect(model.phase == .profileSaveFailed)

        await model.continueWithoutSaving(using: service) {
            dismissed = true
        }

        #expect(service.createCount == 1)
        #expect(service.publishCount == 1)
        #expect(service.completeCount == 1)
        #expect(dismissed)
    }

    @Test func photoPreparationRejectsUndecodableBytes() async {
        await #expect {
            try await ProfileImageDraftProcessor.prepare(
                data: Data([0]), fileName: "broken.jpg", typeIdentifier: nil
            )
        } throws: { error in
            guard let failure = error as? MediaDraftProcessor.Failure,
                  case .unsupportedImage = failure else { return false }
            return true
        }
    }

    @Test func avatarPreparationUsesTheFixedStandardImageContract() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 3_000, height: 1_500),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_500))
        }
        let png = try #require(image.pngData())

        let draft = try await ProfileImageDraftProcessor.prepare(
            data: png,
            fileName: "avatar.png",
            typeIdentifier: "public.png",
            sourceURL: URL(string: "https://example.com/avatar.png")
        )

        #expect(draft.sourceURL == "https://example.com/avatar.png")
        #expect(draft.mediaType == "image/jpeg")
        #expect(draft.dim == "2048x1024")
        #expect(draft.data.count <= MediaDraftProcessor.maxImageAttachmentBytes)
        #expect(draft.thumbnail != nil)
    }

    private static let avatarDraft = GroupImageUploadDraft(
        data: Data([0x01, 0x02, 0x03]),
        mediaType: "image/jpeg",
        sourceURL: nil,
        dim: "1x1",
        thumbhash: nil,
        thumbnail: nil
    )
}

@MainActor
private final class CreateIdentityServiceStub: CreateIdentityServicing {
    var createFailuresRemaining = 0
    var publishFailuresRemaining = 0

    private(set) var createCount = 0
    private(set) var profileReadCount = 0
    private(set) var uploadCount = 0
    private(set) var publishCount = 0
    private(set) var completeCount = 0
    var beforeCreateReturn: (() async -> Void)?

    let identity = AccountSummaryFfi(
        label: "created",
        accountIdHex: String(repeating: "a", count: 64),
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: true
    )

    func createIdentityForProfileSetup() async throws -> IdentityCreationResultFfi {
        createCount += 1
        if createFailuresRemaining > 0 {
            createFailuresRemaining -= 1
            throw StubError.failed
        }
        await beforeCreateReturn?()
        return IdentityCreationResultFfi(
            account: identity,
            profile: UserProfileMetadataFfi(
                name: "engine-name",
                displayName: "Engine Name",
                about: nil,
                picture: nil,
                banner: "https://example.com/banner.jpg",
                nip05: "engine@example.com",
                lud16: "engine@example.com"
            ),
            readiness: .localReady
        )
    }

    func uploadOnboardingAvatar(
        accountRef: String,
        draft: GroupImageUploadDraft
    ) async throws -> String {
        uploadCount += 1
        return "https://example.com/avatar.jpg"
    }

    func publishOnboardingProfile(
        accountRef: String,
        profile: UserProfileMetadataFfi
    ) async throws {
        publishCount += 1
        if publishFailuresRemaining > 0 {
            publishFailuresRemaining -= 1
            throw StubError.failed
        }
    }

    func completeIdentityProfileSetup(_ summary: AccountSummaryFfi) async {
        completeCount += 1
    }

    private enum StubError: Error {
        case failed
    }
}

private actor IdentityCreationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
