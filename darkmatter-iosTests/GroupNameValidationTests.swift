import Testing
@testable import darkmatter_ios

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

    @Test func newChatGroupDescriptionTrimsAndDropsBlankValues() {
        #expect(NewChatSheet.normalizedGroupDescription("") == nil)
        #expect(NewChatSheet.normalizedGroupDescription(" \n\t ") == nil)
        let description = NewChatSheet.normalizedGroupDescription("  Mission notes  ")
        #expect(description == "Mission notes")
    }
}
