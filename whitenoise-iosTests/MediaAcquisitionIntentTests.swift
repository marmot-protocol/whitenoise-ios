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

    @Test func sharedMediaTileAppearanceStaysAutomaticUntilATap() async {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            throw AttachmentReadError.unavailable
        }
        var didFail = false
        func load(_ demand: AttachmentDemand) async {
            if (try? await loader.data(for: attachment(), demand: demand)) == nil {
                didFail = demand.failureOffersRetry
            }
        }
        for _ in 0..<3 {
            guard let demand = GroupSharedMediaThumbnailDemand.onAppear(autoDownloadAllowed: true) else { continue }
            await load(demand)
        }
        // Reappearing may repeat automatic demand; MDK keeps the durable history, and
        // only a tap on a tile showing Retry asks it to download again.
        #expect(requests == [.automatic, .automatic, .automatic])
        await load(GroupSharedMediaThumbnailDemand.onTap(didFail: didFail))
        await load(GroupSharedMediaThumbnailDemand.onTap(didFail: didFail))
        #expect(requests.suffix(2) == [.explicit, .retry])
    }

    @Test func policyBlockedSharedMediaTileWaitsForAnExplicitTap() async {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            return Data([1])
        }
        if let demand = GroupSharedMediaThumbnailDemand.onAppear(autoDownloadAllowed: false) {
            _ = try? await loader.data(for: attachment(), demand: demand)
        }
        #expect(requests.isEmpty)
        _ = try? await loader.data(for: attachment(), demand: GroupSharedMediaThumbnailDemand.onTap(didFail: false))
        #expect(requests == [.explicit])
    }

    @Test func aTapDuringAnAutomaticLoadSupersedesIt() {
        var loads = GroupSharedMediaThumbnailLoadGate()
        let automatic = loads.begin()
        let tap = loads.begin()
        #expect(loads.isLoading)
        #expect(!loads.owns(automatic))
        // The superseded automatic load finishing cannot clear the tap's spinner or record its outcome.
        loads.finish(automatic)
        #expect(loads.isLoading)
        #expect(loads.owns(tap))
        loads.finish(tap)
        #expect(!loads.isLoading)
    }

    @Test func aPolicyRevisionDuringALoadStartsAFreshOne() {
        var loads = GroupSharedMediaThumbnailLoadGate()
        let cancelled = loads.begin()
        let replacement = loads.begin()
        loads.finish(cancelled)
        #expect(loads.owns(replacement))
        #expect(loads.isLoading)
    }

    @Test func automaticFailureLeavesTheFirstTapExplicit() {
        // Appearance load fails (e.g. a failed or retry-exhausted source).
        var showsRetry = AttachmentDemand.automatic.failureOffersRetry
        #expect(!showsRetry)
        let firstTap = AttachmentDemand.userTap(afterFailure: showsRetry)
        #expect(firstTap == .explicit)
        // MDK does not re-arm the source, so the tap fails and surfaces Retry.
        showsRetry = firstTap.failureOffersRetry
        #expect(showsRetry)
        #expect(AttachmentDemand.userTap(afterFailure: showsRetry) == .retry)
        #expect(AttachmentDemand.retry.failureOffersRetry)
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
