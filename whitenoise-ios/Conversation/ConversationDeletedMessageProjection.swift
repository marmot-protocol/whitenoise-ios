import Foundation
import MarmotKit

/// Tombstone projection for the conversation timeline: folds the authoritative
/// projected deletes (mirrored from timeline rows at ingest) and the local
/// optimistic deletes into a single `deletedMessageIds` set.
///
/// The last of the optimistic-overlay projections peeled out of the view model
/// ahead of the TimelineStore core, sibling to the markdown/media/reaction
/// caches. `isDeleted` (and the reaction recompute, which takes the set as an
/// input) read through this; every mutation path bumps
/// `timelineProjectionGeneration` in the view model, so SwiftUI observation is
/// unchanged.
@MainActor
final class ConversationDeletedMessageProjection {
    private var projected: Set<String> = []
    private var sources: [String: DeletionSourceFfi] = [:]
    private var publishedSources: [String: DeletionSourceFfi] = [:]
    private var optimistic: Set<String> = []
    private(set) var deletedMessageIds: Set<String> = []

    func contains(_ messageIdHex: String) -> Bool {
        deletedMessageIds.contains(messageIdHex)
    }

    func source(for messageIdHex: String) -> DeletionSourceFfi {
        publishedSources[messageIdHex] ?? .unknown
    }

    // MARK: Projected deletes (ingest write-path)

    func setProjected(deleted: Bool, source: DeletionSourceFfi = .unknown, forMessageId messageIdHex: String) {
        sources[messageIdHex] = deleted ? source : nil
        if deleted {
            projected.insert(messageIdHex)
        } else {
            projected.remove(messageIdHex)
        }
    }

    func removeProjected(forMessageId messageIdHex: String) {
        projected.remove(messageIdHex)
        sources[messageIdHex] = nil
    }

    // MARK: Optimistic deletes

    var hasOptimistic: Bool { !optimistic.isEmpty }

    func insertOptimistic(_ messageIdHex: String) {
        optimistic.insert(messageIdHex)
    }

    func removeOptimistic(_ messageIdHex: String) {
        optimistic.remove(messageIdHex)
    }

    func removeAllOptimistic() {
        optimistic.removeAll()
    }

    // MARK: Aggregation

    @discardableResult
    func rebuild() -> Bool {
        let next = projected.union(optimistic)
        guard deletedMessageIds != next || publishedSources != sources else { return false }
        publishedSources = sources
        deletedMessageIds = next
        return true
    }
}
