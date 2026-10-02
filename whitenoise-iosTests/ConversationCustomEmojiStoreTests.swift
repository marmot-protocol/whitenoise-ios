import CryptoKit
import Foundation
import Testing
import UIKit
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct ConversationCustomEmojiStoreTests {
    typealias F = CustomEmojiFixtures

    @MainActor final class Harness {
        var scope: CustomEmojiScope? = CustomEmojiScope(accountRef: "alice", runtimeGeneration: 1, groupIdHex: "g1")
        var loadError: Error?
        var listMediaCalls = 0
        var records: [MediaRecordFfi] = []
        /// Per-call results; falls back to `records` once exhausted.
        var recordBatches: [[MediaRecordFfi]] = []
        var loadRequests: [MessageMediaAttachment] = []
        var payload = Data("emoji".utf8)
        var candidate: MessageMediaAttachment?
        var beforeLoadReturns: (() -> Void)?
        var listGate: CheckedContinuation<Void, Never>?
        var holdsListMedia = false

        lazy var store = ConversationCustomEmojiStore(
            scopeProvider: { [unowned self] in self.scope },
            listMedia: { [unowned self] _ in
                let call = self.listMediaCalls
                self.listMediaCalls += 1
                let result = call < self.recordBatches.count ? self.recordBatches[call] : self.records
                if self.holdsListMedia {
                    await withCheckedContinuation { self.listGate = $0 }
                }
                return result
            },
            loadData: { [unowned self] item in
                self.loadRequests.append(item)
                self.beforeLoadReturns?()
                if let error = self.loadError { throw error }
                return self.payload
            },
            loadableAttachment: { [unowned self] _ in self.candidate },
            decode: { _, _, _ in
                UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
            }
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func inlineItem(_ harness: Harness) -> MessageMediaAttachment {
        F.attachments([.accepted(attachmentIndex: 0,
            reference: F.reference(url: "https://blossom.example.com/party", sha: Self.sha256(harness.payload)))])[0]
    }

    @Test func inlineLoadIsAutomaticAndCachedPerScope() async {
        let harness = Harness()
        let item = inlineItem(harness)
        let first = await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1")
        #expect(first != nil)
        #expect(harness.loadRequests.count == 1)
        #expect(harness.loadRequests.first?.downloadExplicitly == false)
        #expect(harness.loadRequests.first?.localTarget != nil)
        let cached = await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1")
        #expect(cached === first)
        #expect(harness.loadRequests.count == 1)

        // Another account (or runtime, or chat) never sees the cached image.
        harness.scope = CustomEmojiScope(accountRef: "bob", runtimeGeneration: 1, groupIdHex: "g1")
        let other = await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1")
        #expect(other !== first)
        #expect(harness.loadRequests.count == 2)
    }

    @Test func policyBlockedLoadIsRetriedOnlyAfterThePolicyChanges() async {
        let harness = Harness()
        let item = inlineItem(harness)
        harness.loadError = AttachmentReadError.unavailable
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "cellular") == nil)
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "cellular") == nil)
        #expect(harness.loadRequests.count == 1)
        harness.loadError = nil
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "wifi") != nil)
        #expect(harness.loadRequests.count == 2)
    }

    @Test func verificationFailureWaitsForAPolicyChange() async {
        let harness = Harness()
        let item = inlineItem(harness)
        harness.payload = Data("tampered".utf8)
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1") == nil)
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1") == nil)
        #expect(harness.loadRequests.count == 1)
        harness.payload = Data("emoji".utf8)
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p2") != nil)
        #expect(harness.loadRequests.count == 2)
    }

    @Test func lateResultAfterAccountSwitchIsIgnored() async {
        let harness = Harness()
        let item = inlineItem(harness)
        harness.beforeLoadReturns = { harness.scope = CustomEmojiScope(accountRef: "bob", runtimeGeneration: 1, groupIdHex: "g1") }
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1") == nil)
        // Switching back does not resurrect the late result.
        harness.beforeLoadReturns = nil
        harness.scope = CustomEmojiScope(accountRef: "alice", runtimeGeneration: 1, groupIdHex: "g1")
        harness.loadError = AttachmentReadError.unavailable
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1") == nil)
        #expect(harness.loadRequests.count == 2)
    }

    @Test func reactionResolvesThroughListMediaAndAMatchingChatSlot() async {
        let harness = Harness()
        let reactionID = String(repeating: "7a", count: 32)
        let sha = Self.sha256(harness.payload)
        let reference = F.reference(url: "https://blossom.example.com/cat", sha: sha)
        harness.records = [F.mediaRecord(messageID: reactionID, caption: ":cat:", reference: reference)]
        harness.candidate = inlineItem(harness)
        let image = await harness.store.reactionImage(emoji: ":cat:", reactionMessageIdHex: reactionID,
            pixelSize: 48, scale: 3, policyRevision: "p1")
        #expect(image != nil)
        #expect(harness.listMediaCalls == 1)
        #expect(harness.loadRequests.first?.id == harness.candidate?.id)
        #expect(harness.loadRequests.first?.downloadExplicitly == false)
        #expect(harness.store.reactionCatalogEntries.map(\.shortcode.name) == ["cat"])
        #expect(harness.store.reactionCatalogEntries.first?.source
            == .reaction(reactionMessageIdHex: reactionID, attachmentIndex: 0))
    }

    @Test func unresolvableReactionsFallBackWithoutRepeatedLookups() async {
        let harness = Harness()
        let reactionID = String(repeating: "7a", count: 32)
        harness.records = [F.mediaRecord(messageID: reactionID, caption: ":cat:",
            reference: F.reference(url: "https://blossom.example.com/cat"))]
        // No chat slot holds the same plaintext: MDK cannot serve the bytes, so text.
        #expect(await harness.store.reactionImage(emoji: ":cat:", reactionMessageIdHex: reactionID,
            pixelSize: 48, scale: 3, policyRevision: "p1") == nil)
        #expect(harness.loadRequests.isEmpty)
        // A reaction id missing from listMedia stays text and is not re-queried.
        let missing = String(repeating: "00", count: 32)
        #expect(await harness.store.reactionImage(emoji: ":dog:", reactionMessageIdHex: missing,
            pixelSize: 48, scale: 3, policyRevision: "p1") == nil)
        #expect(await harness.store.reactionImage(emoji: ":dog:", reactionMessageIdHex: missing,
            pixelSize: 48, scale: 3, policyRevision: "p1") == nil)
        #expect(harness.listMediaCalls == 2)
        // Unicode emoji and missing ids never query.
        #expect(await harness.store.reactionImage(emoji: "👍", reactionMessageIdHex: reactionID,
            pixelSize: 48, scale: 3, policyRevision: "p1") == nil)
        #expect(await harness.store.reactionImage(emoji: ":cat:", reactionMessageIdHex: nil,
            pixelSize: 48, scale: 3, policyRevision: "p1") == nil)
        #expect(harness.listMediaCalls == 2)
    }

    @Test func concurrentReactionLookupsShareOneListMediaPass() async {
        let harness = Harness()
        let first = String(repeating: "7a", count: 32)
        let second = String(repeating: "7b", count: 32)
        let cat = F.mediaRecord(messageID: first, caption: ":cat:", reference: F.reference(url: "https://blossom.example.com/cat"))
        let dog = F.mediaRecord(messageID: second, caption: ":dog:", reference: F.reference(url: "https://blossom.example.com/dog"))
        // The first pass started before `second` existed; the next one sees it.
        harness.recordBatches = [[cat], [cat, dog]]
        harness.holdsListMedia = true
        async let a = harness.store.reactionImage(emoji: ":cat:", reactionMessageIdHex: first,
            pixelSize: 48, scale: 3, policyRevision: "p1")
        while harness.listGate == nil { await Task.yield() }
        async let b = harness.store.reactionImage(emoji: ":dog:", reactionMessageIdHex: second,
            pixelSize: 48, scale: 3, policyRevision: "p1")
        await Task.yield()
        harness.holdsListMedia = false
        harness.listGate?.resume()
        _ = await (a, b)
        // `second` was requested mid-flight and missing from that pass, so it
        // needed exactly one more; `first` was answered by the shared pass.
        #expect(harness.listMediaCalls == 2)
        #expect(Set(harness.store.reactionCatalogEntries.map(\.shortcode.name)) == ["cat", "dog"])
    }

    @Test func inFlightPassThatAlreadyHoldsALateIdAnswersIt() async {
        let harness = Harness()
        let first = String(repeating: "7a", count: 32)
        let second = String(repeating: "7b", count: 32)
        harness.records = [
            F.mediaRecord(messageID: first, caption: ":cat:", reference: F.reference(url: "https://blossom.example.com/cat")),
            F.mediaRecord(messageID: second, caption: ":dog:", reference: F.reference(url: "https://blossom.example.com/dog")),
        ]
        harness.holdsListMedia = true
        async let a = harness.store.reactionImage(emoji: ":cat:", reactionMessageIdHex: first,
            pixelSize: 48, scale: 3, policyRevision: "p1")
        while harness.listGate == nil { await Task.yield() }
        async let b = harness.store.reactionImage(emoji: ":dog:", reactionMessageIdHex: second,
            pixelSize: 48, scale: 3, policyRevision: "p1")
        await Task.yield()
        harness.holdsListMedia = false
        harness.listGate?.resume()
        _ = await (a, b)
        #expect(harness.listMediaCalls == 1)
        #expect(Set(harness.store.reactionCatalogEntries.map(\.shortcode.name)) == ["cat", "dog"])
    }

    @Test func scopeChangeDuringLookupDropsTheResult() async {
        let harness = Harness()
        let reactionID = String(repeating: "7a", count: 32)
        harness.records = [F.mediaRecord(messageID: reactionID, caption: ":cat:",
            reference: F.reference(url: "https://blossom.example.com/cat", sha: Self.sha256(harness.payload)))]
        harness.candidate = inlineItem(harness)
        harness.holdsListMedia = true
        async let image = harness.store.reactionImage(emoji: ":cat:", reactionMessageIdHex: reactionID,
            pixelSize: 48, scale: 3, policyRevision: "p1")
        while harness.listGate == nil { await Task.yield() }
        harness.scope = CustomEmojiScope(accountRef: "alice", runtimeGeneration: 2, groupIdHex: "g1")
        harness.listGate?.resume()
        #expect(await image == nil)
        #expect(harness.loadRequests.isEmpty)
        #expect(harness.store.reactionCatalogEntries.isEmpty)
    }
}
