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

    @Test func publishRejectsReentrantCallsAtEntry() throws {
        // The publish side effect goes through the real Marmot client, so pin the
        // view-model's synchronous entry guard as the first statement: a second
        // tap must return before any draft/client/publish work starts.
        let source = try sourceString("whitenoise-ios/Settings/ProfileEditViewModel.swift")

        #expect(source.matches(#"func publish\(using appState: AppState\) async \{\s*guard !isPublishing else \{ return \}"#))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
