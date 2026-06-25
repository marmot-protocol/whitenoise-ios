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

    @Test func publishRejectsReentrantCallsBeforeStartingWork() throws {
        // The publish side effect goes through the real Marmot client, so pin the
        // view-model's synchronous entry guard at the source boundary: a second
        // tap must return before reading the draft or publishing kind:0 metadata.
        let source = try sourceString("darkmatter-ios/Settings/ProfileEditViewModel.swift")

        #expect(source.matches(#"func publish\(using appState: AppState\) async \{\s*guard !isPublishing else \{ return \}[\s\S]*let draft = currentDraft"#))
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
