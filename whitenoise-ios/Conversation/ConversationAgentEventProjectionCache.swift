// swiftlint:disable no_test_hook_in_app_code
import Foundation
import MarmotKit

@MainActor
final class ConversationAgentEventProjectionCache {
    private struct ProjectionKey: Equatable {
        let kind: UInt64
        let plaintext: String
        let status: String?
        let operation: String?
        let operationName: String?

        init(record: AppMessageRecordFfi) {
            kind = record.kind
            plaintext = record.plaintext
            status = MessageSemantics.firstValue(of: "status", in: record.tags)
            operation = MessageSemantics.firstValue(of: "operation", in: record.tags)
            operationName = MessageSemantics.firstValue(of: "operation-name", in: record.tags)
        }
    }

    private struct Entry {
        let key: ProjectionKey
        let display: AgentEventPresentation.Display?
    }

    private var entriesByRowId: [String: Entry] = [:]

#if DEBUG
    private(set) var buildCountForTesting = 0
#endif

    func display(for item: TimelineItem) -> AgentEventPresentation.Display? {
        guard case .message(let record, _) = item.kind else { return nil }
        let key = ProjectionKey(record: record)
        if let cached = entriesByRowId[item.id], cached.key == key {
            return cached.display
        }

        let display: AgentEventPresentation.Display?
        switch MessageSemantics.classify(record) {
        case .agentActivity, .agentOperation:
            display = AgentEventPresentation.display(for: record)
        default:
            display = nil
        }
#if DEBUG
        buildCountForTesting += 1
#endif
        entriesByRowId[item.id] = Entry(key: key, display: display)
        return display
    }

    func remove(rowId: String) {
        entriesByRowId[rowId] = nil
    }

    func prune(keeping rowIds: Set<String>) {
        for rowId in Array(entriesByRowId.keys) where !rowIds.contains(rowId) {
            entriesByRowId[rowId] = nil
        }
    }
}
