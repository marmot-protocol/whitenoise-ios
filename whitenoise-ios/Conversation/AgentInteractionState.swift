import Foundation
import Observation
import MarmotKit

/// The Marmot calls `ConversationViewModel` makes to send kind-1202 agent
/// answers/controls, read back uncertain admissions, and attribute settled
/// kind-1202 requests to their sender.
nonisolated struct AgentRequestCalls: Sendable {
    var sendCustomEvent: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String, _ payload: AgentRequestPayload, _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi
    var localSendStatus: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String, _ clientToken: String
    ) async throws -> LocalSendStatusFfi?
    var loadKind1202Messages: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String, _ limit: UInt32?
    ) async throws -> [AppMessageRecordFfi] = { appState, accountRef, groupIdHex, limit in
        try await appState.currentMarmotClient().groupMessages(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            limit: limit,
            kinds: [MessageSemantics.kindAgentOperation]
        )
    }

    static let live = AgentRequestCalls(
        sendCustomEvent: { appState, accountRef, groupIdHex, payload, clientToken in
            try await appState.currentMarmotClient().sendCustomEventWithClientToken(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                kind: payload.kind,
                tags: payload.tags,
                content: payload.content,
                clientToken: clientToken
            )
        },
        localSendStatus: { appState, accountRef, groupIdHex, clientToken in
            try await appState.currentMarmotClient().localSendStatus(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                clientToken: clientToken
            )
        }
    )
}

/// Tracks in-flight and pending kind-1202 answers and controls for a conversation,
/// enforcing `docs/design/answers-and-controls.md`:
/// - An answer or control stays pending until a later version of some item
///   (or agent message) lists its event id in `settles`.
/// - Tracks who sent settled kind-1202 events so the UI can show who answered.
///
/// Privacy invariant (D-071): never logs request text, secrets, keys, or group ids.
@Observable
@MainActor
final class AgentInteractionStore {
    struct PendingRequest: Equatable, Sendable {
        let key: String
        let clientToken: String
        let payload: AgentRequestPayload
        let summary: String
        let senderAccountIdHex: String
        var requestEventIdHex: String?
        var sendFailed: Bool = false
        var statusUnknown: Bool = false
    }

    typealias SendCustomEventOperation = @MainActor (
        _ payload: AgentRequestPayload,
        _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi

    typealias LocalSendStatusOperation = @MainActor (
        _ clientToken: String
    ) async throws -> LocalSendStatusFfi?

    /// Active pending requests keyed by target/control key.
    private(set) var pendingByKey: [String: PendingRequest] = [:]
    /// Known senders (accountIdHex) of kind-1202 request events, keyed by event id.
    private(set) var requestSenderByEventId: [String: String] = [:]
    /// All event IDs observed in any `settles` tag/field across the conversation.
    private(set) var settledEventIds: Set<String> = []
    /// Event IDs we already asked MDK storage to resolve senders for.
    @ObservationIgnored private var queriedKind1202ForSettledIds: Set<String> = []

    static func itemKey(targetEventIdHex: String) -> String {
        "item:\(targetEventIdHex)"
    }

    static func stopKey(agentPubkeyHex: String, targetEventIdHex: String?) -> String {
        "stop:\(agentPubkeyHex):\(targetEventIdHex ?? "turn")"
    }

    static func newSessionKey(agentPubkeyHex: String) -> String {
        "new_session:\(agentPubkeyHex)"
    }

    static func setSettingKey(agentPubkeyHex: String, settingId: String) -> String {
        "set:\(agentPubkeyHex):\(settingId)"
    }

    static func ownActionKey(agentPubkeyHex: String, actionId: String) -> String {
        "own:\(agentPubkeyHex):\(actionId)"
    }

    func pendingRequest(forKey key: String) -> PendingRequest? {
        pendingByKey[key]
    }

    func pendingRequest(forItemEventId messageIdHex: String) -> PendingRequest? {
        pendingByKey[Self.itemKey(targetEventIdHex: messageIdHex)]
    }

    func isPending(key: String) -> Bool {
        guard let pending = pendingByKey[key] else { return false }
        return !pending.sendFailed
    }

    /// Repeatable controls stay tappable while `statusUnknown` is true so the
    /// user can trigger a status recheck (and retry if MDK rejected the send).
    func isControlDisabled(key: String) -> Bool {
        guard let pending = pendingByKey[key] else { return false }
        return !pending.sendFailed && !pending.statusUnknown
    }

    /// Returns the account ID hex of the person who answered/triggered the item
    /// if any event id in `item.settles` has a known sender.
    func settledByAccountId(for projection: AgentItemProjection) -> String? {
        for eventId in projection.item.settles {
            if let sender = requestSenderByEventId[eventId] {
                return sender
            }
        }
        return nil
    }

    /// Records senders learned from durable kind-1202 records in MDK storage.
    func recordRequestSenders(_ records: [AppMessageRecordFfi]) {
        for record in records where record.kind == MessageSemantics.kindAgentOperation {
            guard !record.messageIdHex.isEmpty, !record.sender.isEmpty else { continue }
            if requestSenderByEventId[record.messageIdHex] != record.sender {
                requestSenderByEventId[record.messageIdHex] = record.sender
            }
        }
    }

    /// Returns settled event IDs whose sender is unknown and has not yet been queried.
    func unknownSettledEventIds(in projections: [AgentItemProjection]) -> Set<String> {
        var missing: Set<String> = []
        for projection in projections {
            for eventId in projection.item.settles {
                if requestSenderByEventId[eventId] == nil && !queriedKind1202ForSettledIds.contains(eventId) {
                    missing.insert(eventId)
                }
            }
        }
        return missing
    }

    func markSettledIdsQueried(_ ids: Set<String>) {
        queriedKind1202ForSettledIds.formUnion(ids)
    }

    /// Reconciles pending requests against the latest set of settled event IDs
    /// observed across all loaded items and agent messages.
    func reconcile(settledEventIds latestSettled: Set<String>) {
        if latestSettled != settledEventIds {
            settledEventIds = latestSettled
        }
        guard !pendingByKey.isEmpty else { return }
        for (key, pending) in pendingByKey {
            if let eventId = pending.requestEventIdHex, latestSettled.contains(eventId) {
                pendingByKey.removeValue(forKey: key)
            }
        }
    }

    /// Sends a kind-1202 request, tracking it as pending until settled by an item's `settles`.
    /// When an error leaves admission ambiguous (such as cancellation or worker timeout),
    /// probes `checkStatus` with the same `clientToken` before resending:
    /// - Confirmed admission recovers without sending again.
    /// - Confirmed rejection allows minting a fresh token.
    /// - A missing status (`nil`) never mints a fresh token; only retrying the exact
    ///   same payload reuses the original `clientToken` (which MDK deduplicates).
    @discardableResult
    func submit(
        key: String,
        summary: String,
        senderAccountIdHex: String,
        payload: AgentRequestPayload,
        checkStatus: LocalSendStatusOperation? = nil,
        send: SendCustomEventOperation
    ) async throws -> LocalSendAcceptanceFfi? {
        var reusableToken: String?
        if let existing = pendingByKey[key], !existing.sendFailed {
            guard existing.statusUnknown, let checkStatus else {
                return existing.requestEventIdHex.map {
                    LocalSendAcceptanceFfi(clientToken: existing.clientToken, messageIdHex: $0)
                }
            }
            let status: LocalSendStatusFfi?
            do {
                status = try await checkStatus(existing.clientToken)
            } catch {
                return nil
            }
            guard pendingByKey[key]?.clientToken == existing.clientToken else {
                return nil
            }
            if let resolved = applySendStatus(
                key: existing.key,
                token: existing.clientToken,
                senderAccountIdHex: existing.senderAccountIdHex,
                status: status,
                ambiguousWhenMissing: true
            ) {
                return resolved
            }
            if pendingByKey[key]?.sendFailed != true {
                guard existing.payload == payload else {
                    return nil
                }
                reusableToken = existing.clientToken
            }
        }

        let token = reusableToken ?? UUID().uuidString
        let pending = PendingRequest(
            key: key,
            clientToken: token,
            payload: payload,
            summary: summary,
            senderAccountIdHex: senderAccountIdHex,
            requestEventIdHex: nil,
            sendFailed: false,
            statusUnknown: false
        )
        pendingByKey[key] = pending
        do {
            let acceptance = try await send(payload, token)
            recordAccepted(
                key: key,
                token: token,
                messageIdHex: acceptance.messageIdHex,
                senderAccountIdHex: senderAccountIdHex
            )
            return acceptance
        } catch {
            if let checkStatus {
                do {
                    let status = try await checkStatus(token)
                    if let recovered = applySendStatus(
                        key: key,
                        token: token,
                        senderAccountIdHex: senderAccountIdHex,
                        status: status,
                        ambiguousWhenMissing: MediaSubmissionRecovery.isAmbiguousWithoutStatus(error)
                    ) {
                        return recovered
                    }
                } catch {
                    if pendingByKey[key]?.clientToken == token {
                        pendingByKey[key]?.sendFailed = false
                        pendingByKey[key]?.statusUnknown = true
                    }
                }
            } else if pendingByKey[key]?.clientToken == token {
                let ambiguous = MediaSubmissionRecovery.isAmbiguousWithoutStatus(error)
                pendingByKey[key]?.sendFailed = !ambiguous
                pendingByKey[key]?.statusUnknown = ambiguous
            }
            throw error
        }
    }

    private func recordAccepted(
        key: String,
        token: String,
        messageIdHex: String,
        senderAccountIdHex: String
    ) {
        if !messageIdHex.isEmpty {
            requestSenderByEventId[messageIdHex] = senderAccountIdHex
        }
        guard pendingByKey[key]?.clientToken == token else { return }
        if !messageIdHex.isEmpty && settledEventIds.contains(messageIdHex) {
            pendingByKey.removeValue(forKey: key)
        } else {
            pendingByKey[key]?.requestEventIdHex = messageIdHex.isEmpty ? nil : messageIdHex
            pendingByKey[key]?.sendFailed = false
            pendingByKey[key]?.statusUnknown = false
        }
    }

    private func applySendStatus(
        key: String,
        token: String,
        senderAccountIdHex: String,
        status: LocalSendStatusFfi?,
        ambiguousWhenMissing: Bool
    ) -> LocalSendAcceptanceFfi? {
        guard pendingByKey[key]?.clientToken == token else { return nil }
        switch status {
        case .queued(let messageIdHex), .engineOwned(let messageIdHex):
            recordAccepted(
                key: key,
                token: token,
                messageIdHex: messageIdHex,
                senderAccountIdHex: senderAccountIdHex
            )
            return LocalSendAcceptanceFfi(clientToken: token, messageIdHex: messageIdHex)
        case .completed(let summary):
            let messageIdHex = summary.messageIds.first ?? ""
            recordAccepted(
                key: key,
                token: token,
                messageIdHex: messageIdHex,
                senderAccountIdHex: senderAccountIdHex
            )
            return LocalSendAcceptanceFfi(clientToken: token, messageIdHex: messageIdHex)
        case .rejected, .refusedNewMembers:
            pendingByKey[key]?.sendFailed = true
            pendingByKey[key]?.statusUnknown = false
            return nil
        case nil:
            pendingByKey[key]?.sendFailed = !ambiguousWhenMissing
            pendingByKey[key]?.statusUnknown = ambiguousWhenMissing
            return nil
        }
    }

    func clearFailed(key: String) {
        if pendingByKey[key]?.sendFailed == true {
            pendingByKey.removeValue(forKey: key)
        }
    }
}
