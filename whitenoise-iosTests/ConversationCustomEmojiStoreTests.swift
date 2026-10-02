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
        var loadRequests: [MessageMediaAttachment] = []
        var payload = Data("emoji".utf8)
        var beforeLoadReturns: (() -> Void)?

        lazy var store = ConversationCustomEmojiStore(
            scopeProvider: { [weak self] in self?.scope },
            loadData: { [weak self] item in
                guard let self else { throw CancellationError() }
                self.loadRequests.append(item)
                self.beforeLoadReturns?()
                if let error = self.loadError { throw error }
                return self.payload
            },
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
        #expect(harness.loadRequests.first?.demand == .automatic)
        #expect(harness.loadRequests.first?.localTarget != nil)
        let cached = await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1")
        #expect(cached?.image === first?.image)
        #expect(cached?.key == first?.key)
        #expect(harness.loadRequests.count == 1)

        // Another account (or runtime, or chat) never sees the cached image.
        harness.scope = CustomEmojiScope(accountRef: "bob", runtimeGeneration: 1, groupIdHex: "g1")
        let other = await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1")
        #expect(other?.image !== first?.image)
        #expect(other?.key.scope.accountRef == "bob")
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

    @Test func loadedImageIsWithheldOnceTheScopeChanges() async throws {
        let harness = Harness()
        let item = inlineItem(harness)
        let party = try #require(CustomEmojiShortcode("party"))
        let resolution = CustomEmojiRowResolution(inline: [party: item], gridItems: [])
        let loaded = try #require(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1"))
        let images = [loaded.key: loaded.image]
        let shown = CustomEmojiInlinePresentation.images(for: resolution, loaded: images,
            scope: harness.store.currentScope, pixelSize: 60)
        #expect(shown[party] === loaded.image)

        // Runtime restart, account switch, no scope, or a new size: the same
        // view state publishes nothing until a load under the new key lands.
        let restarted = CustomEmojiScope(accountRef: "alice", runtimeGeneration: 2, groupIdHex: "g1")
        let otherAccount = CustomEmojiScope(accountRef: "bob", runtimeGeneration: 1, groupIdHex: "g1")
        for scope in [restarted, otherAccount] as [CustomEmojiScope?] + [nil] {
            #expect(CustomEmojiInlinePresentation.images(for: resolution, loaded: images, scope: scope, pixelSize: 60).isEmpty)
        }
        #expect(CustomEmojiInlinePresentation.images(for: resolution, loaded: images,
            scope: harness.store.currentScope, pixelSize: 90).isEmpty)
        // A row whose inline attachment changed does not reuse the old image.
        let other = CustomEmojiFixtures.attachments([.accepted(attachmentIndex: 1,
            reference: CustomEmojiFixtures.reference(url: "https://blossom.example.com/other"))])[0]
        #expect(CustomEmojiInlinePresentation.images(for: CustomEmojiRowResolution(inline: [party: other], gridItems: []),
            loaded: images, scope: harness.store.currentScope, pixelSize: 60).isEmpty)

        // The store itself also refuses a new scope's request from cache.
        harness.scope = nil
        #expect(harness.store.currentScope == nil)
        #expect(await harness.store.inlineImage(for: item, pixelSize: 60, scale: 3, policyRevision: "p1") == nil)
        #expect(harness.loadRequests.count == 1)
    }
}
