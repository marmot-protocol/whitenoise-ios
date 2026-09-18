import Foundation
import SwiftUI
import Testing
@testable import whitenoise_ios

struct WNDropdownItemTests {

    @Test func rowsAreOrdinaryUnlessMarkedDestructive() {
        let ordinary = WNDropdownItem(id: "files", title: "Files", systemImage: "folder")
        let destructive = WNDropdownItem(
            id: "remove",
            title: "Remove Photo",
            systemImage: "trash",
            isDestructive: true
        )

        #expect(!ordinary.isDestructive)
        #expect(destructive.isDestructive)
    }

    @Test func theSelectionValueIdentifiesTheRow() {
        let item = WNDropdownItem(id: "camera", title: "Camera", systemImage: "camera")
        #expect(item.id == "camera")
    }

    @Test func rowsWithDifferentSelectionsAreNotEqual() {
        let camera = WNDropdownItem(id: "camera", title: "Camera", systemImage: "camera")
        let files = WNDropdownItem(id: "files", title: "Camera", systemImage: "camera")
        #expect(camera != files)
    }
}
