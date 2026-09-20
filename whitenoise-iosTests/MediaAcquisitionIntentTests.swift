import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct MediaAcquisitionIntentTests {
    private func attachment(_ mediaType: String = "image/jpeg") -> MessageMediaAttachment {
        MessageMediaAttachment(id: "source-slot", reference: nil, fileName: "attachment",
            mediaType: mediaType, dim: nil, localData: nil)
    }

    @Test func neighbouringGalleryPagesNeverInvokeTheDownloader() async throws {
        var requests = [Bool]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.downloadExplicitly)
            return Data([1])
        }
        for _ in 0..<5 {
            #expect(try await loader.selectedPageData(for: attachment(), isSelected: false) == nil)
        }
        #expect(requests.isEmpty)
        #expect(try await loader.selectedPageData(for: attachment(), isSelected: true) == Data([1]))
        #expect(requests == [true])
    }

    @Test func documentPrefetchRequiresVisibilityAndPermissionAndNeverEscalatesFailure() async {
        var requests = [Bool]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.downloadExplicitly)
            throw AttachmentReadError.unavailable
        }
        let document = attachment("application/pdf")
        await loader.prefetchDocument(document, isVisible: false, allowed: true)
        await loader.prefetchDocument(document, isVisible: true, allowed: false)
        await loader.prefetchDocument(attachment(), isVisible: true, allowed: true)
        #expect(requests.isEmpty)
        await loader.prefetchDocument(document, isVisible: true, allowed: true)
        #expect(requests == [false])
        // Reappearing may repeat demand, but cannot reset MDK's durable download history.
        await loader.prefetchDocument(document, isVisible: true, allowed: true)
        #expect(requests == [false, false])
    }
}
