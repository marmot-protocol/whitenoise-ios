import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ProfileEditViewTests {
    @MainActor
    @Test func profileSaveIsDisabledForInvalidDraft() {
        let viewModel = ProfileEditViewModel()

        viewModel.picture = "not-a-url"
        #expect(viewModel.currentDraft.validationError == .picture)
        #expect(viewModel.invalidPictureMessage == L10n.string("Change or remove this photo before saving your profile."))

        viewModel.picture = "https://cdn.example.com/avatar.png"
        #expect(viewModel.currentDraft.validationError == nil)
        #expect(viewModel.invalidPictureMessage == nil)

        viewModel.nip05 = "alice example.com"
        #expect(viewModel.currentDraft.validationError == .nip05)
        #expect(viewModel.invalidNip05Message == L10n.string("Enter an address like name@example.com."))

        viewModel.nip05 = "alice@example.com"
        #expect(viewModel.currentDraft.validationError == nil)
        #expect(viewModel.invalidNip05Message == nil)
    }

    @Test func profileMetadataDraftSanitizesEditableFields() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: " Alice\u{202E}\nEvil ",
            about: String(repeating: "a", count: ContentSanitizer.maxAboutLength + 25),
            picture: "",
            nip05: " ALICE@Example.COM ",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)

        #expect(metadata.name == "Alice Evil")
        #expect(metadata.displayName == "Alice Evil")
        #expect(metadata.about?.count == ContentSanitizer.maxAboutLength)
        #expect(metadata.nip05 == "alice@example.com")
    }

    @Test func profilePreservesExistingLud16Verbatim() throws {
        // lud16 is not editable here; whatever the profile already had must
        // round-trip unchanged so a kind:0 replacement never wipes it.
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: "",
            nip05: "",
            preservedLud16: "weird-but-existing"
        )

        #expect(draft.validationError == nil)
        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.picture == nil)
        #expect(metadata.lud16 == "weird-but-existing")
    }

    @Test func profileMetadataDraftRejectsInvalidNip05BeforePublish() {
        let invalidNip05 = ProfileEditMetadataDraft(
            displayName: "", about: "", picture: "", nip05: "alice example.com",
            preservedLud16: nil
        )

        #expect(invalidNip05.validationError == .nip05)
        #expect(invalidNip05.normalizedMetadata == nil)
    }
}
