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

        let selections = PhotoLibrarySelection.compactPreservingPickerOrder([first, nil, third])

        #expect(selections.map(\.fileName) == ["first.jpg", "third.jpg"])
    }
}
