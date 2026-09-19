import Foundation
import Testing
import Synchronization
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct Marmot0102IntegrationTests {
    @Test func retainedReadsRespectOffsetsAndRevocation() async throws {
        let offsets = Mutex<[UInt64]>([])
        let data = try await RetainedAttachmentReader.read(byteCount: 3) { offset, limit in
            #expect(limit <= 1_048_576)
            offsets.withLock { $0.append(offset) }
            return AttachmentLocalBytesFfi(available: true, bytes: offset == 0 ? Data([1, 2]) : offset == 2 ? Data([3]) : Data())
        }
        #expect(data == Data([1, 2, 3]))
        #expect(offsets.withLock { $0 } == [0, 2, 3])
        await #expect(throws: AttachmentReadError.self) {
            try await RetainedAttachmentReader.read(byteCount: 2) { offset, _ in
                AttachmentLocalBytesFfi(available: offset == 0, bytes: offset == 0 ? Data([1]) : Data())
            }
        }
        let empty = try await RetainedAttachmentReader.read(byteCount: 0) { _, _ in
            AttachmentLocalBytesFfi(available: true, bytes: Data())
        }
        #expect(empty.isEmpty)
        await #expect(throws: AttachmentReadError.self) {
            try await RetainedAttachmentReader.read(byteCount: 2) { _, _ in
                AttachmentLocalBytesFfi(available: true, bytes: Data())
            }
        }
    }

    @Test func deletionProvenanceChangesWithoutChangingTombstone() {
        let projection = ConversationDeletedMessageProjection()
        projection.setProjected(deleted: true, source: .unknown, forMessageId: "message")
        #expect(projection.rebuild())
        projection.setProjected(deleted: true, source: .admin, forMessageId: "message")
        #expect(projection.rebuild())
        #expect(projection.source(for: "message") == .admin)
        projection.removeProjected(forMessageId: "message")
        #expect(projection.rebuild())
        #expect(projection.source(for: "message") == .unknown)
        projection.insertOptimistic("pending")
        projection.rebuild()
        #expect(projection.source(for: "pending") == .unknown)
    }

    @Test func conversationMilestonesAreOnceOnlyAndRespectConsentRevocation() async throws {
        let recorder = ProductAnalyticsRecorder()
        let samples = Mutex<[(HostPerformanceOperationFfi, HostPerformanceOutcomeFfi)]>([])
        recorder.activateSink(performance: { operation, _, outcome in
            samples.withLock { $0.append((operation, outcome)) }
        }) { _ in }
        let tracker = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        tracker.rendered(local: true, composer: nil, recorder: recorder)
        tracker.rendered(local: true, composer: false, recorder: recorder)
        tracker.finish(.cancelled, recorder: recorder)
        // The recorder's queue is intentionally asynchronous and bounded.
        for _ in 0..<100 where samples.withLock({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(samples.withLock { $0.count } == 2)
        #expect(samples.withLock { $0.contains { $0.0 == .conversationComposerReady && $0.1 == .unavailable } })
        let revoked = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        recorder.replaceSink(nil)
        revoked.rendered(local: true, composer: true, recorder: recorder)
        #expect(samples.withLock { $0.count } == 2)
    }

    @Test func attachmentHistoryPolicyAndCancellationUsePublishedBinary() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = MarmotFixtureWatchdog.start("0.10.2 attachments", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Attachment bindings", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            var policy = try await client.marmot.attachmentDownloadPolicy(accountRef: account.label)
            policy.automatic = false
            try await client.marmot.setAttachmentDownloadPolicy(accountRef: account.label, policy: policy)
            #expect(try await client.marmot.attachmentDownloadPolicy(accountRef: account.label) == policy)
            let result = try await client.marmot.attachmentHistoryPage(accountRef: account.label,
                groupIdHex: group.groupIdHex, limit: 10, cursor: nil)
            guard case .page(let page) = result else { Issue.record("Expected an empty page"); return }
            #expect(page.entries.isEmpty && !page.hasMore)
            let version = try await client.marmot.attachmentHistoryVersion(accountRef: account.label, groupIdHex: group.groupIdHex)
            #expect(version.changeSince(previous: page.version) == .unchanged)
            let target = AttachmentLocalTargetFfi(messageIdHex: String(repeating: "a", count: 64),
                sourceMessageIdHex: String(repeating: "b", count: 64), attachmentIndex: 2)
            let assets = try await client.marmot.attachmentLocalAssets(accountRef: account.label,
                groupIdHex: group.groupIdHex, targets: [target, target])
            #expect(assets.count == 2 && assets.allSatisfy { $0.reference == nil })
            let subscription = try await client.marmot.subscribeAttachmentTransfers(accountRef: account.label,
                groupIdHex: group.groupIdHex, targets: [target])
            #expect(try await subscription.next()?.items.first?.state == .unavailable)
            let reader = Task { try await subscription.next() }
            subscription.cancel()
            #expect(try await reader.value == nil)
            #expect(try await client.marmot.downloadAttachmentAgain(accountRef: account.label,
                groupIdHex: group.groupIdHex, target: target) == nil)
            // Offline creation may not have authored a current package yet. A local read must still succeed.
            let inventory = try client.marmot.localAccountKeyPackages(accountRef: account.label)
            #expect(inventory.allSatisfy { $0.record.accountIdHex == account.accountIdHex })
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
}
