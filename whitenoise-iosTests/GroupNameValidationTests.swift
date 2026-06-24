import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// #80 — a group rename must reject an empty/whitespace name so the shared group
/// name can't be silently blanked.
@MainActor
struct GroupNameValidationTests {

    @Test func rejectsEmptyOrWhitespaceDraft() {
        #expect(GroupDetailsView.validatedGroupName("") == nil)
        #expect(GroupDetailsView.validatedGroupName("   \n\t ") == nil)
    }

    @Test func trimsAndAcceptsNonEmptyName() {
        #expect(GroupDetailsView.validatedGroupName("  Team Rocket  ") == "Team Rocket")
    }

    @Test func renameDraftSanitizesAndCapsGroupName() throws {
        let hostile = "\u{202E}Team\nRocket" + String(repeating: "x", count: 150)
        let sanitized = try #require(GroupDetailsView.validatedGroupName(hostile))

        #expect(sanitized.hasPrefix("Team Rocket"))
        #expect(!sanitized.contains("\u{202E}"))
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.count == ProfileSanitizer.maxGroupNameLength)
    }

    @Test func newChatGroupNameUsesSanitizedEmptyStringSentinel() {
        #expect(NewChatSheet.normalizedGroupName("") == "")
        #expect(NewChatSheet.normalizedGroupName(" \n\t ") == "")
        #expect(NewChatSheet.normalizedGroupName(" \u{202E}Research\nLab ") == "Research Lab")
    }

    @Test func newChatGroupDescriptionSanitizesCapsAndDropsBlankValues() {
        #expect(NewChatSheet.normalizedGroupDescription("") == nil)
        #expect(NewChatSheet.normalizedGroupDescription(" \n\t ") == nil)
        let description = NewChatSheet.normalizedGroupDescription("  Mission\u{202E}\n\n\nnotes  ")
        #expect(description == "Mission\n\nnotes")

        let oversized = NewChatSheet.normalizedGroupDescription(String(repeating: "x", count: 500))
        #expect(oversized?.count == ProfileSanitizer.maxGroupDescriptionLength)
    }
}
