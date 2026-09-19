import Foundation
import Observation

@MainActor
@Observable
final class ChatListBulkLeaveState {
    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        let context: ChatLeaveOperation.Context
        let targets: [ChatListLeavePresentation.Target]
        let requiresSelfDemotion: Bool
    }

    struct Result {
        let failedIDs: Set<String>
        let pendingIDs: Set<String>
    }

    private(set) var confirmation: Confirmation?
    private(set) var isPreparing = false
    private(set) var processingID: String?
    private(set) var retainedIDs = Set<String>()
    private var approved: Confirmation?
    var isBusy: Bool { isPreparing || approved != nil }

    func prepare(
        context: ChatLeaveOperation.Context,
        targets: [ChatListLeavePresentation.Target],
        isCurrent: () -> Bool,
        validate: (ChatListLeavePresentation.Target) async throws -> Bool
    ) async throws {
        guard !isBusy, confirmation == nil, !targets.isEmpty, isCurrent() else { return }
        isPreparing = true
        defer { isPreparing = false; processingID = nil }
        var requiresSelfDemotion = false
        for target in targets {
            guard !Task.isCancelled, isCurrent() else { return }
            processingID = target.groupIdHex
            let selfDemotion = try await validate(target)
            requiresSelfDemotion = requiresSelfDemotion || selfDemotion
        }
        guard !Task.isCancelled, isCurrent() else { return }
        confirmation = Confirmation(context: context, targets: targets, requiresSelfDemotion: requiresSelfDemotion)
    }

    func cancelConfirmation() { confirmation = nil }

    func approve(_ value: Confirmation, isCurrent: Bool) -> Bool {
        guard !isBusy, confirmation == value, isCurrent else { return false }
        confirmation = nil
        approved = value
        retainedIDs.formUnion(value.targets.map(\.groupIdHex))
        return true
    }

    func runApproved(
        isCurrent: () -> Bool,
        leave: (ChatListLeavePresentation.Target) async -> ChatLeaveOperation.Result
    ) async -> Result? {
        guard let approved else { return nil }
        defer { self.approved = nil; processingID = nil }
        var failedIDs = Set<String>()
        var pendingIDs = Set<String>()
        for target in approved.targets {
            guard !Task.isCancelled, isCurrent() else { return nil }
            processingID = target.groupIdHex
            switch await leave(target) {
            case .left: break
            case .pending: pendingIDs.insert(target.groupIdHex)
            case .failed, .blocked: failedIDs.insert(target.groupIdHex)
            case .cancelled: return nil
            }
        }
        guard !Task.isCancelled, isCurrent() else { return nil }
        return Result(failedIDs: failedIDs, pendingIDs: pendingIDs)
    }

    func clearSelection() {
        confirmation = nil
        retainedIDs = []
    }
}
