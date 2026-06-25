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
            picture: "",
            nip05: "alice@example.com",
            lud16: ""
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
            picture: "",
            nip05: "",
            lud16: ""
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.name == nil)
        #expect(metadata.displayName == "Alice 🎉")
    }
}
