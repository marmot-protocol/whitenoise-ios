import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

struct ChatListSelectionTests {
    @Test func archiveTogglesToUnarchiveOnlyWhenAllArchived() {
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [true, true]) == .unarchive)
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [true, false]) == .archive)
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [false, false]) == .archive)
        // Empty selection never resolves to unarchive.
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: []) == .archive)
    }

    @Test func muteTogglesToUnmuteOnlyWhenAllMuted() {
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: [true, true]) == false)
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: [true, false]) == true)
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: []) == true)
    }

    @Test func toggleAndReconcile() {
        var selected: Set<String> = []
        selected = ChatListSelection.toggling(selected, id: "a")
        selected = ChatListSelection.toggling(selected, id: "b")
        #expect(selected == ["a", "b"])
        selected = ChatListSelection.toggling(selected, id: "a")
        #expect(selected == ["b"])
        // A selection whose chat scrolled out of the visible set is dropped.
        #expect(ChatListSelection.reconcile(["a", "b"], visibleIds: ["b", "c"]) == ["b"])
        #expect(ChatListSelection.selectAll(["a", "b", "c"]) == ["a", "b", "c"])
    }

    // MARK: - Select all toggle

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

struct MessageBulkCopyTests {
    @Test func combinedCopyPreservesLongMessagesAndTheirWhitespace() {
        let first = "  **Heading**\n\n" + String(repeating: "First message\n", count: 150) + "\n"
        let second = "\t```swift\nlet value = 1\n```\n\n[link](https://example.com)  "
        let records = [first, second].map { source in
            var record = message(id: hex("aa"), plaintext: source)
            record.contentTokens = MarkdownDocumentFfi(
                blocks: [.paragraph(inlines: [.text(content: source)])], truncated: false
            )
            return record
        }
        let bodies = records.map { MessagePreview.copyBody($0) }

        #expect(MessageSelectionPolicy.combinedCopyText([""] + bodies + [" \n\t"]) == first + "\n\n" + second)
    }

    @Test func combinedCopyJoinsNonEmptyBodiesInOrder() {
        let text = MessageSelectionPolicy.combinedCopyText(["first", "  ", "second", ""])
        #expect(text == "first\n\nsecond")
        #expect(MessageSelectionPolicy.canCopy(selectedCount: 2, anyHasText: true))
        #expect(!MessageSelectionPolicy.canCopy(selectedCount: 0, anyHasText: true))
        #expect(!MessageSelectionPolicy.canCopy(selectedCount: 2, anyHasText: false))
    }
}
