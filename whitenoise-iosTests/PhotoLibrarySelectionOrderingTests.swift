import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct PhotoLibrarySelectionOrderingTests {

    @Test func compactingLoadedSelectionsPreservesPickerOrder() {
        let first = PhotoLibrarySelection(data: Data([1]), fileName: "first.jpg")
        let second = PhotoLibrarySelection(data: Data([2]), fileName: "second.jpg")
        let third = PhotoLibrarySelection(data: Data([3]), fileName: "third.jpg")
        var slots = [PhotoLibrarySelection?](repeating: nil, count: 3)

        slots[2] = third
        slots[0] = first
        slots[1] = second

        let selections = PhotoLibrarySelection.compactPreservingPickerOrder(slots)

        #expect(selections.map(\.fileName) == ["first.jpg", "second.jpg", "third.jpg"])
    }

    @Test func compactingLoadedSelectionsDropsUnreadableSlotsWithoutReordering() {
        let first = PhotoLibrarySelection(data: Data([1]), fileName: "first.jpg")
        let third = PhotoLibrarySelection(data: Data([3]), fileName: "third.jpg")
        // The size gate runs before any bytes are materialized in memory.
        #expect(!PhotoLibrarySelection.admitsSelection(bytes: 0, cap: 100))
        #expect(PhotoLibrarySelection.admitsSelection(bytes: 100, cap: 100))
        #expect(!PhotoLibrarySelection.admitsSelection(bytes: 101, cap: 100))
        // Under the per-item cap but over the remaining session budget: the
        // sum of accepted selections is bounded, not just each item.
        #expect(!PhotoLibrarySelection.admitsSelection(bytes: 80, cap: 100, remaining: 50))
        #expect(PhotoLibrarySelection.admitsSelection(bytes: 50, cap: 100, remaining: 50))
        // An image sends at most its re-encoded size, so a large photo fits
        // where a video of the same source size does not.
        let source = 4 * MediaDraftProcessor.maxImageAttachmentBytes
        let room = 2 * MediaDraftProcessor.maxImageAttachmentBytes
        let imageCost = PhotoLibrarySelection.budgetCost(bytes: source, kind: .image)
        let videoCost = PhotoLibrarySelection.budgetCost(bytes: source, kind: .video)
        #expect(PhotoLibrarySelection.admitsSelection(bytes: source, cap: .max, cost: imageCost, remaining: room))
        #expect(!PhotoLibrarySelection.admitsSelection(bytes: source, cap: .max, cost: videoCost, remaining: room))

        let selections = PhotoLibrarySelection.compactPreservingPickerOrder([first, nil, third])

        #expect(selections.map(\.fileName) == ["first.jpg", "third.jpg"])
    }

    @Test func aPickerSessionStartsWithTheRoomLeftBesideTheComposer() {
        let video = MediaDraftAttachment(fileName: "clip.mov", mediaType: "video/quicktime", data: Data(count: 1_000), dim: nil)

        #expect(PhotoLibrarySelection.remainingBudget(alongside: []) == PhotoLibrarySelection.maxTotalSelectionBytes)
        #expect(PhotoLibrarySelection.remainingBudget(alongside: [video]) < PhotoLibrarySelection.maxTotalSelectionBytes - 1_000)
    }
}
