import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct HistoryImportPresentationTests {
    private let slot = hex("d1")

    @Test func theDividerSitsAboveTheFirstLiveMessageAfterImportedOnes() {
        let timeline = ["1", "2", "3", "4"].map { TimelineItem.message(message(id: hex($0)), status: .received) }
        let fromMac = HistoryImportOrigin.device(slotIdHex: slot, label: "Mac")
        let boundaries = HistoryImportBoundaryProjection.boundaries(
            for: timeline, origins: [hex("1"): fromMac, hex("2"): fromMac]
        )
        #expect(boundaries == [timeline[2].id: fromMac])
        // All imported, or all live: nothing to mark.
        #expect(HistoryImportBoundaryProjection.boundaries(for: timeline, origins: [:]).isEmpty)
        let allImported = Dictionary(uniqueKeysWithValues: ["1", "2", "3", "4"].map { (hex($0), fromMac) })
        #expect(HistoryImportBoundaryProjection.boundaries(for: timeline, origins: allImported).isEmpty)
    }

    @Test func provenanceDecidesBetweenADeviceAndABackup() {
        let source = HistoryImportSourceFfi(deviceSlotIdHex: slot, deviceLabel: "Mac")
        #expect(HistoryImportOrigin(importedFrom: source, provenance: nil) == .device(slotIdHex: slot, label: "Mac"))
        #expect(HistoryImportOrigin(importedFrom: source, provenance: .device(deviceSlotIdHex: slot))
            == .device(slotIdHex: slot, label: "Mac"))
        #expect(HistoryImportOrigin(importedFrom: nil, provenance: nil) == nil)
    }

    @Test func theDividerNamesTheDeviceItsCurrentNameOrAGenericOne() {
        let origin = HistoryImportOrigin.device(slotIdHex: slot, label: "Old name")
        let current = HistoryImportPresentation.dividerText(origin, deviceName: "MacBook")
        #expect(current.contains("MacBook"))
        #expect(HistoryImportPresentation.dividerText(origin, deviceName: nil).contains("Old name"))
        let unnamed = HistoryImportPresentation.dividerText(.device(slotIdHex: slot, label: " "), deviceName: nil)
        #expect(!unnamed.isEmpty)
        #expect(unnamed != HistoryImportPresentation.dividerText(.backup, deviceName: nil))
    }

    @Test func theArrivingNoticeShowsOnlyWhileHistoryIsStillComing() {
        let receiving = HistoryImportPresentation.arrivingNotice(.receiving(retrying: false))
        let retrying = HistoryImportPresentation.arrivingNotice(.receiving(retrying: true))
        #expect(receiving != nil)
        #expect(retrying != nil && retrying != receiving)
        let done = ChatHistoryImportStateFfi.imported(
            from: HistoryImportSourceFfi(deviceSlotIdHex: slot, deviceLabel: "Mac"), at: 1
        )
        #expect(HistoryImportPresentation.arrivingNotice(done) == nil)
        #expect(HistoryImportPresentation.arrivingNotice(nil) == nil)
    }
}
