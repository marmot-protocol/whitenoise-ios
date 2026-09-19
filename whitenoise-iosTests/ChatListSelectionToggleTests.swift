import Testing
@testable import whitenoise_ios

struct ChatListSelectionToggleTests {
    @Test func emptyListDoesNotOfferDeselectAll() {
        #expect(!ChatListSelection.allSelected([], visibleIds: []))
        #expect(ChatListSelection.togglingAll(["old"], visibleIds: []).isEmpty)
    }

    @Test func partialSelectionSelectsEveryVisibleChat() {
        #expect(!ChatListSelection.allSelected(["a"], visibleIds: ["a", "b"]))
        #expect(ChatListSelection.togglingAll(["a"], visibleIds: ["a", "b"]) == ["a", "b"])
    }

    @Test func completeSelectionTogglesBackToEmpty() {
        #expect(ChatListSelection.allSelected(["a", "b"], visibleIds: ["a", "b"]))
        #expect(ChatListSelection.togglingAll(["a", "b"], visibleIds: ["a", "b"]).isEmpty)
    }

    @Test func filteredScopeNeverAddsHiddenChats() {
        #expect(ChatListSelection.togglingAll(["hidden"], visibleIds: ["visible"]) == ["visible"])
        #expect(ChatListSelection.togglingAll(["hidden", "visible"], visibleIds: ["visible"]).isEmpty)
    }
}
