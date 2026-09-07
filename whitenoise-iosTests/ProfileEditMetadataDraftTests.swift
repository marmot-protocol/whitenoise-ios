import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ProfileEditMetadataDraftTests {
    @MainActor
    @Test func accountTransitionResetsEditableFieldsWhenTheLoadWindowOpens() {
        let model = ProfileEditViewModel()
        // Account A: fresh identity, user typed a draft; load settles.
        let ticketA = model.beginLoadAttempt(accountIdHex: "account-a")
        model.displayName = "Alice draft"
        model.about = "About A"
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil, ticket: ticketA)
        #expect(model.displayName == "Alice draft")
        #expect(model.loadedAccountIdHex == "account-a")

        // Switching to B resets the form the moment B's window opens — not
        // at completion — so nothing typed for A is ever visible or
        // publishable under B, even if B's load never completes.
        let ticketB = model.beginLoadAttempt(accountIdHex: "account-b")
        #expect(model.displayName.isEmpty)
        #expect(model.about.isEmpty)
        #expect(model.loadedAccountIdHex == nil)
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-b", profile: nil, ticket: ticketB)
        #expect(model.loadedAccountIdHex == "account-b")
    }

    @MainActor
    @Test func discardedMidSwitchLoadCannotLeakItsDraftIntoTheNextAccount() {
        let model = ProfileEditViewModel()
        let ticketA = model.beginLoadAttempt(accountIdHex: "account-a")
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil, ticket: ticketA)

        // B's window opens and the user types while B's read is in flight;
        // the active account returns to A before B completes, so B's outcome
        // is never applied.
        model.beginLoadAttempt(accountIdHex: "account-b")
        model.displayName = "Bob draft"

        // A's new window must see B as the last attempt and reset — the
        // failure mode was recording attempts only at completion, which made
        // this look like a same-account edit and preserved Bob's draft.
        let ticketA2 = model.beginLoadAttempt(accountIdHex: "account-a")
        #expect(model.displayName.isEmpty)
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil, ticket: ticketA2)
        #expect(model.loadedAccountIdHex == "account-a")
    }

    @MainActor
    @Test func staleTicketedOutcomesAreDroppedWhole() {
        let model = ProfileEditViewModel()
        let staleTicket = model.beginLoadAttempt(accountIdHex: "account-a")
        let currentTicket = model.beginLoadAttempt(accountIdHex: "account-a")

        // A detached read from the superseded window completes late: it must
        // not re-authorize Save while the newer load is still in flight.
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil, ticket: staleTicket)
        #expect(model.loadedAccountIdHex == nil)

        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil, ticket: currentTicket)
        #expect(model.loadedAccountIdHex == "account-a")
    }

    @MainActor
    @Test func sameAccountRetryAfterFailureClearsTheStaleError() {
        let model = ProfileEditViewModel()
        let failedTicket = model.beginLoadAttempt(accountIdHex: "account-a")
        model.applyLoadOutcome(.loadFailed, accountIdHex: "account-a", profile: nil, ticket: failedTicket)
        #expect(model.error != nil)

        // The screen's task restarts for the same account and the retry
        // resolves as a fresh identity: Save arms, so the failure message
        // from the superseded window must not linger.
        let retryTicket = model.beginLoadAttempt(accountIdHex: "account-a")
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil, ticket: retryTicket)
        #expect(model.error == nil)
        #expect(model.loadedAccountIdHex == "account-a")
    }

    @MainActor
    @Test func failedReadRevokesAuthorizationEntirely() {
        let model = ProfileEditViewModel()
        let ticketA = model.beginLoadAttempt(accountIdHex: "account-a")
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil, ticket: ticketA)

        let ticketB = model.beginLoadAttempt(accountIdHex: "account-b")
        model.applyLoadOutcome(.loadFailed, accountIdHex: "account-b", profile: nil, ticket: ticketB)
        #expect(model.error != nil)
        // A failed load revokes authorization entirely — a stale grant from
        // the previously loaded account would re-arm Save the moment the
        // active account switches back, with whatever the form then holds.
        #expect(model.loadedAccountIdHex == nil)
    }

    @Test func formFieldsFallBackToNameWhenDisplayNameIsMissing() {
        let profile = UserProfileMetadataFfi(
            name: "alice",
            displayName: nil,
            about: nil,
            picture: nil,
            banner: "https://example.com/banner.png",
            nip05: nil,
            lud16: nil
        )

        let formFields = ProfileEditFormFields(profile: profile)
        #expect(formFields.displayName == "alice")
        #expect(formFields.banner == "https://example.com/banner.png")
    }

    @Test func formFieldsPreferDisplayNameWhenBothNamesDiffer() {
        let profile = UserProfileMetadataFfi(
            name: "old-generated-name",
            displayName: "Current Name",
            about: nil,
            picture: nil,
            banner: nil,
            nip05: nil,
            lud16: nil
        )

        #expect(ProfileEditFormFields(profile: profile).displayName == "Current Name")
    }

    @Test func publishesEditedNameToBothNostrNameFields() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice 🎉",
            about: "",
            picture: "",
            nip05: "alice@example.com",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.name == "Alice 🎉")
        #expect(metadata.displayName == "Alice 🎉")
        #expect(metadata.nip05 == "alice@example.com")
    }

    @Test func blankVisibleNameClearsBothNostrNameFields() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: "   ",
            about: "",
            picture: "",
            nip05: "",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.name == nil)
        #expect(metadata.displayName == nil)
    }

    @Test func normalizesValidHttpsPictureURL() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: " https://cdn.example.com/avatar.png ",
            nip05: "",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.picture == "https://cdn.example.com/avatar.png")
    }

    @Test func carriesForwardExistingBannerVerbatim() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: "",
            nip05: "",
            preservedBanner: "https://cdn.example.com/banner.png",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.banner == "https://cdn.example.com/banner.png")
        #expect(metadata.ffi.banner == "https://cdn.example.com/banner.png")
    }

    @Test func absentBannerPublishesNothingRatherThanBlanking() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: "",
            nip05: "",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.banner == nil)
    }

    @Test func rejectsInvalidPictureURLBeforePublish() {
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: "http://legacy.example/a.png",
            nip05: "",
            preservedLud16: nil
        )

        #expect(draft.validationError == .picture)
        #expect(draft.normalizedMetadata == nil)
    }

    @Test func blankPictureClearsPublishedMetadata() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: "   ",
            nip05: "",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.picture == nil)
    }

    /// The form has no banner field, so a banner the sanitizer would reject must
    /// not gate Save — it is echoed back exactly as it was loaded.
    @Test func unsanitizableExistingBannerNeitherBlocksSaveNorIsRewritten() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: "",
            nip05: "",
            preservedBanner: "http://legacy.example/banner.png",
            preservedLud16: nil
        )

        #expect(draft.validationError == nil)
        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.banner == "http://legacy.example/banner.png")
    }

    @Test func seedsEmptyFieldOnSameAccountReloadWithoutClobberingEdits() {
        #expect(ProfileEditFieldSeeding.seeded(current: "", loaded: "Alice", isNewAccount: false) == "Alice")
        #expect(ProfileEditFieldSeeding.seeded(current: "Al", loaded: "Alice", isNewAccount: false) == "Al")
    }

    @Test func firstLoadDoesNotCountAsDifferentLoadedAccount() {
        #expect(!ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: nil, loading: "account-a"))
        // A fresh identity (projection exists, no kind:0 anywhere) unlocks a
        // first publish; a failed load stays gated — publishing then could
        // replace existing metadata with blanks.
        // The throwing read is the only authority: failure gates outright,
        // a successful nil is definitive absence, and the display cache has
        // no vote (a stale projection must neither seed nor unlock Save).
        #expect(ProfileEditLoadResolution.resolve(
            hasLoadedProfile: false, readFailed: false
        ) == .enableFirstPublish)
        #expect(ProfileEditLoadResolution.resolve(
            hasLoadedProfile: false, readFailed: true
        ) == .loadFailed)
        #expect(ProfileEditLoadResolution.resolve(
            hasLoadedProfile: true, readFailed: false
        ) == .seedExisting)
        #expect(!ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: "account-a", loading: "account-a"))
        #expect(ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: "account-a", loading: "account-b"))
    }

    @Test func adoptsDifferentAccountValueEvenWhenFieldIsNonEmpty() {
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "Bob", isNewAccount: true) == "Bob")
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "", isNewAccount: true) == "")
    }
}

struct MarmotKitBuildLabelTests {
    @Test func taggedBuildShowsVersionAndShortHash() {
        #expect(
            MarmotKitBuildLabel.text(
                tag: "marmotkit-v0.9.5",
                sha: "5729f6cde28323b3"
            ) == "MarmotKit v0.9.5 (5729f6cd)"
        )
    }

    @Test func sourceBuildOmitsVersionEvenWhenBuiltFromTaggedCommit() {
        #expect(
            MarmotKitBuildLabel.text(
                tag: "marmotkit-v0.9.5",
                sha: "5729f6cd-dirty"
            ) == "MarmotKit (5729f6cd)"
        )
    }

    @Test func untaggedCleanBuildOmitsVersion() {
        #expect(
            MarmotKitBuildLabel.text(
                tag: "",
                sha: "abcdef1234567890"
            ) == "MarmotKit (abcdef12)"
        )
    }
}
