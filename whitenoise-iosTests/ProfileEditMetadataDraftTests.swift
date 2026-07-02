import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ProfileEditMetadataDraftTests {
    @Test func formFieldsPreserveNameWithoutSeedingDisplayNameFromIt() {
        let profile = UserProfileMetadataFfi(
            name: "alice",
            displayName: nil,
            about: nil,
            picture: nil,
            nip05: nil,
            lud16: nil
        )

        let formFields = ProfileEditFormFields(profile: profile)
        #expect(formFields.name == "alice")
        #expect(formFields.displayName == "")
    }

    @Test func preservesExistingNameWhenDisplayNameChanges() throws {
        let draft = ProfileEditMetadataDraft(
            name: "alice",
            displayName: "Alice 🎉",
            about: "",
            nip05: "alice@example.com",
            preservedPicture: nil,
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.name == "alice")
        #expect(metadata.displayName == "Alice 🎉")
        #expect(metadata.nip05 == "alice@example.com")
    }

    @Test func doesNotInventNameFromDisplayName() throws {
        let draft = ProfileEditMetadataDraft(
            name: nil,
            displayName: "Alice 🎉",
            about: "",
            nip05: "",
            preservedPicture: nil,
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.name == nil)
        #expect(metadata.displayName == "Alice 🎉")
    }

    @Test func seedsEmptyFieldOnSameAccountReloadWithoutClobberingEdits() {
        #expect(ProfileEditFieldSeeding.seeded(current: "", loaded: "Alice", isNewAccount: false) == "Alice")
        #expect(ProfileEditFieldSeeding.seeded(current: "Al", loaded: "Alice", isNewAccount: false) == "Al")
    }

    @Test func adoptsNewAccountValueEvenWhenFieldIsNonEmpty() {
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "Bob", isNewAccount: true) == "Bob")
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "", isNewAccount: true) == "")
    }
}
