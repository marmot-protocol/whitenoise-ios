import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@MainActor
struct MediaAcquisitionIntentTests {
    private func attachment(_ mediaType: String = "image/jpeg") -> MessageMediaAttachment {
        MessageMediaAttachment(id: "source-slot", reference: nil, fileName: "attachment",
            mediaType: mediaType, dim: nil, localData: nil)
    }

    @Test func neighbouringGalleryPagesNeverInvokeTheDownloader() async throws {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            return Data([1])
        }
        for _ in 0..<5 {
            #expect(try await loader.selectedPageData(for: attachment(), isSelected: false) == nil)
        }
        #expect(requests.isEmpty)
        #expect(try await loader.selectedPageData(for: attachment(), isSelected: true) == Data([1]))
        #expect(requests == [.explicit])
    }

    @Test func documentPrefetchRequiresVisibilityAndPermissionAndNeverEscalatesFailure() async {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            throw AttachmentReadError.unavailable
        }
        let document = attachment("application/pdf")
        await loader.prefetchDocument(document, isVisible: false, allowed: true)
        await loader.prefetchDocument(document, isVisible: true, allowed: false)
        await loader.prefetchDocument(attachment(), isVisible: true, allowed: true)
        #expect(requests.isEmpty)
        await loader.prefetchDocument(document, isVisible: true, allowed: true)
        #expect(requests == [.automatic])
        // Reappearing may repeat demand, but cannot reset MDK's durable download history.
        await loader.prefetchDocument(document, isVisible: true, allowed: true)
        #expect(requests == [.automatic, .automatic])
    }

    @Test func selectedPageRetryCarriesTheRetryDemand() async throws {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            return Data([1])
        }
        _ = try await loader.selectedPageData(for: attachment(), isSelected: true,
            demand: .userTap(afterFailure: true))
        _ = try await loader.data(for: attachment())
        #expect(requests == [.retry, .explicit])
    }

    @Test func onlyATapOnAFailedAttachmentIsADeliberateRetry() {
        #expect(AttachmentDemand.userTap(afterFailure: false) == .explicit)
        #expect(AttachmentDemand.userTap(afterFailure: true) == .retry)
        #expect(!AttachmentDemand.automatic.isUserInitiated)
        #expect(AttachmentDemand.explicit.isUserInitiated)
        #expect(AttachmentDemand.retry.isUserInitiated)
    }

    private let target = AttachmentLocalTargetFfi(messageIdHex: String(repeating: "a", count: 64),
        sourceMessageIdHex: String(repeating: "b", count: 64), attachmentIndex: 1)

    @Test func tapJoinsTheCurrentSourceWithoutDownloadingAgain() async throws {
        let requester = RecordingAttachmentDemandRequester(reference: "job")
        #expect(try await AttachmentDemand.explicit.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: requester))
        #expect(requester.calls == [.init(kind: .explicit, accountRef: "account-a", groupID: "group-a", target: target)])
    }

    @Test func tapOnAnObsoleteSlotHasNothingToAwait() async throws {
        let requester = RecordingAttachmentDemandRequester(reference: nil)
        #expect(try await !AttachmentDemand.explicit.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: requester))
        #expect(requester.calls.map(\.kind) == [.explicit])
    }

    @Test func deliberateRetryDownloadsAgain() async throws {
        let requester = RecordingAttachmentDemandRequester(reference: "job")
        #expect(try await AttachmentDemand.retry.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: requester))
        #expect(requester.calls == [.init(kind: .downloadAgain, accountRef: "account-a", groupID: "group-a", target: target)])
    }

    @Test func automaticDemandAwaitsOnlyLiveTransfers() async throws {
        let live = RecordingAttachmentDemandRequester(reference: "job", automaticState: .downloading)
        #expect(try await AttachmentDemand.automatic.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: live))
        let failed = RecordingAttachmentDemandRequester(reference: "job", automaticState: .failed)
        #expect(try await !AttachmentDemand.automatic.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: failed))
        #expect((live.calls + failed.calls).map(\.kind) == [.automatic, .automatic])
    }
}

private nonisolated final class RecordingAttachmentDemandRequester: AttachmentDemandRequesting {
    struct Call: Equatable {
        enum Kind { case automatic, explicit, downloadAgain }
        let kind: Kind
        let accountRef: String
        let groupID: String
        let target: AttachmentLocalTargetFfi
    }

    private let reference: String?
    private let automaticState: AttachmentTransferStateFfi
    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    init(reference: String?, automaticState: AttachmentTransferStateFfi = .queued) {
        self.reference = reference
        self.automaticState = automaticState
    }

    private func record(_ kind: Call.Kind, _ accountRef: String, _ groupID: String, _ target: AttachmentLocalTargetFfi) {
        recorded.withLock { $0.append(Call(kind: kind, accountRef: accountRef, groupID: groupID, target: target)) }
    }

    func requestAutomaticAttachment(accountRef: String, groupIdHex: String,
                                    target: AttachmentLocalTargetFfi) async throws -> AutomaticAttachmentRequestFfi {
        record(.automatic, accountRef, groupIdHex, target)
        return AutomaticAttachmentRequestFfi(status: AttachmentTransferStatusFfi(reference: reference,
            state: automaticState, attempt: 0, received: 0, total: nil, retryAt: nil), newlyQueued: true)
    }

    func requestExplicitAttachment(accountRef: String, groupIdHex: String,
                                   target: AttachmentLocalTargetFfi) async throws -> String? {
        record(.explicit, accountRef, groupIdHex, target)
        return reference
    }

    func downloadAttachmentAgain(accountRef: String, groupIdHex: String,
                                 target: AttachmentLocalTargetFfi) async throws -> String? {
        record(.downloadAgain, accountRef, groupIdHex, target)
        return reference
    }
}
