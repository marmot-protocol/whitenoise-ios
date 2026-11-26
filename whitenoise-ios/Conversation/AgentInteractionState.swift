import Foundation
import Observation
import MarmotKit

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
        let targetEventIdHex: String?
        let summary: String
        let senderAccountIdHex: String
        var requestEventIdHex: String?
        var sendFailed: Bool = false
    }

    typealias SendCustomEventOperation = @MainActor (
        _ payload: AgentRequestPayload,
        _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi

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
        var updated = false
        for record in records where record.kind == MessageSemantics.kindAgentOperation {
            guard !record.messageIdHex.isEmpty, !record.sender.isEmpty else { continue }
            if requestSenderByEventId[record.messageIdHex] != record.sender {
                requestSenderByEventId[record.messageIdHex] = record.sender
                updated = true
            }
        }
        _ = updated
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
    @discardableResult
    func submit(
        key: String,
        targetEventIdHex: String?,
        summary: String,
        senderAccountIdHex: String,
        payload: AgentRequestPayload,
        send: SendCustomEventOperation
    ) async throws -> LocalSendAcceptanceFfi {
        let token = UUID().uuidString
        let pending = PendingRequest(
            key: key,
            clientToken: token,
            targetEventIdHex: targetEventIdHex,
            summary: summary,
            senderAccountIdHex: senderAccountIdHex,
            requestEventIdHex: nil,
            sendFailed: false
        )
        pendingByKey[key] = pending
        do {
            let acceptance = try await send(payload, token)
            if !acceptance.messageIdHex.isEmpty {
                requestSenderByEventId[acceptance.messageIdHex] = senderAccountIdHex
            }
            if settledEventIds.contains(acceptance.messageIdHex) {
                if pendingByKey[key]?.clientToken == token {
                    pendingByKey.removeValue(forKey: key)
                }
            } else if pendingByKey[key]?.clientToken == token {
                pendingByKey[key]?.requestEventIdHex = acceptance.messageIdHex
                pendingByKey[key]?.sendFailed = false
            }
            return acceptance
        } catch {
            if pendingByKey[key]?.clientToken == token {
                pendingByKey[key]?.sendFailed = true
            }
            throw error
        }
    }

    func clearFailed(key: String) {
        if pendingByKey[key]?.sendFailed == true {
            pendingByKey.removeValue(forKey: key)
        }
    }

    func reset() {
        pendingByKey.removeAll()
        requestSenderByEventId.removeAll()
        settledEventIds.removeAll()
        queriedKind1202ForSettledIds.removeAll()
    }
}
