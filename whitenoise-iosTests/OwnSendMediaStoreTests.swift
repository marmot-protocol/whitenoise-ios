import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct OwnSendMediaStoreTests {
    @Test func sentRowMediaRendersFromTheBytesThatWereJustSent() {
        var store = OwnSendMediaStore()
        store.retain(draftItem(Data([1, 2, 3])), plaintextSha256: "ABC")

        let overlaid = store.overlay(rowItem(plaintextSha256: "abc"))

        #expect(overlaid.localData == Data([1, 2, 3]))
        #expect(overlaid.reference?.plaintextSha256 == "abc")
        #expect(overlaid.id == "row:abc")
    }

    @Test func otherMediaIsLeftForMdkToLoad() {
        var store = OwnSendMediaStore()
        store.retain(draftItem(Data([1])), plaintextSha256: "abc")

        #expect(store.overlay(rowItem(plaintextSha256: "def")).localData == nil)
    }

    @Test func oldestSendIsEvictedPastTheItemLimit() {
        var store = OwnSendMediaStore()
        for index in 0...OwnSendMediaStore.itemLimit {
            store.retain(draftItem(Data([UInt8(index)])), plaintextSha256: "sha\(index)")
        }

        #expect(store.overlay(rowItem(plaintextSha256: "sha0")).localData == nil)
        #expect(store.overlay(rowItem(plaintextSha256: "sha1")).localData == Data([1]))
    }

    @Test func oldestSendIsEvictedPastTheByteBudget() {
        var store = OwnSendMediaStore()
        let half = OwnSendMediaStore.byteBudget / 2 + 1
        store.retain(draftItem(Data(count: half)), plaintextSha256: "first")
        store.retain(draftItem(Data(count: half)), plaintextSha256: "second")

        #expect(store.overlay(rowItem(plaintextSha256: "first")).localData == nil)
        #expect(store.overlay(rowItem(plaintextSha256: "second")).localData?.count == half)
    }
}

private func draftItem(_ data: Data) -> MessageMediaAttachment {
    MediaDraftAttachment(fileName: "photo.jpg", mediaType: "image/jpeg", data: data, dim: nil).displayItem
}

private func rowItem(plaintextSha256: String) -> MessageMediaAttachment {
    MessageMediaAttachment(
        id: "row:\(plaintextSha256)",
        reference: MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/photo")],
            ciphertextSha256: String(repeating: "a", count: 64),
            plaintextSha256: plaintextSha256,
            nonceHex: String(repeating: "2", count: 24),
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            version: .v1,
            sourceEpoch: 1,
            dim: nil,
            thumbhash: nil
        ),
        fileName: "photo.jpg",
        mediaType: "image/jpeg",
        dim: nil,
        localData: nil
    )
}
