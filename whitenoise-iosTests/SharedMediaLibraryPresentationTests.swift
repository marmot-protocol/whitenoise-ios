import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct SharedMediaLibraryPresentationTests {
    @Test func extractsHttpLinksFromChatMessagesOnly() {
        let records = [
            record("m1", kind: 9, content: "look at https://example.com/page and http://other.example.org", at: 20),
            record("m2", kind: 1210, content: "https://ignored.example.com", at: 15),
            record("m3", kind: 9, content: "no links here", at: 10),
        ]

        let links = SharedMediaLibraryPresentation.linkItems(from: records)

        #expect(links.map(\.urlString) == ["https://example.com/page", "http://other.example.org"])
        #expect(links.allSatisfy { $0.messageIdHex == "m1" })
        #expect(links.first?.timelineAt == 20)
    }

    @Test func extractsMarkdownDestinationsAndFlagsInternationalizedHosts() {
        let records = [
            record("m1", kind: 9, content: "see [docs](https://example.com/docs) and https://xn--e1awd7f.example/x", at: 4)
        ]

        let links = SharedMediaLibraryPresentation.linkItems(from: records)

        #expect(links.map(\.urlString) == ["https://example.com/docs", "https://xn--e1awd7f.example/x"])
        #expect(links.map(\.hasInternationalizedHost) == [false, true])
    }

    @Test func trimsWrappingPunctuationAndValidatesShape() {
        #expect(SharedMediaLibraryPresentation.normalizedLink("(https://example.com/a).") == "https://example.com/a")
        #expect(SharedMediaLibraryPresentation.normalizedLink("\"https://example.com\"") == "https://example.com")
        #expect(SharedMediaLibraryPresentation.normalizedLink("ftp://example.com") == nil)
        #expect(SharedMediaLibraryPresentation.normalizedLink("https://") == nil)
        #expect(SharedMediaLibraryPresentation.normalizedLink("example.com") == nil)
        let oversized = "https://example.com/" + String(repeating: "x", count: 2100)
        #expect(SharedMediaLibraryPresentation.normalizedLink(oversized) == nil)
    }

    @Test func deduplicatesRepeatedLinksWithinAMessageButNotAcrossMessages() {
        let records = [
            record("m1", kind: 9, content: "https://example.com https://EXAMPLE.com", at: 9),
            record("m2", kind: 9, content: "https://example.com", at: 5),
        ]

        let links = SharedMediaLibraryPresentation.linkItems(from: records)

        #expect(links.count == 2)
        #expect(Set(links.map(\.messageIdHex)) == ["m1", "m2"])
    }

    @Test func emptyMessageIdsStillProduceUniqueLinkItemIds() {
        let records = [
            record("", kind: 9, content: "https://one.example/path", at: 9),
            record("", kind: 9, content: "https://two.example/path", at: 5),
        ]

        let links = SharedMediaLibraryPresentation.linkItems(from: records)

        #expect(links.count == 2)
        #expect(Set(links.map(\.id)).count == 2)
    }

    @Test func boundsDisplayTextForHostileUrls() {
        let long = "https://example.com/" + String(repeating: "a", count: 500)
        let links = SharedMediaLibraryPresentation.linkItems(from: [record("m1", kind: 9, content: long, at: 1)])

        #expect(links.count == 1)
        #expect((links.first?.display.count ?? 0) <= 120)
    }

    @Test func splitsVoiceFromFilesByAttachmentKind() {
        let items = GroupSharedMediaPresentation.items(from: [
            libraryMediaRecord("voice-message", mediaType: "audio/mp4", fileName: "note.m4a", timestamp: 30),
            libraryMediaRecord("document-message", mediaType: "application/pdf", fileName: "notes.pdf", timestamp: 20),
            libraryMediaRecord("image-message", mediaType: "image/jpeg", fileName: "photo.jpg", timestamp: 10),
        ])

        let voice = SharedMediaLibraryPresentation.voiceItems(from: items)
        let files = SharedMediaLibraryPresentation.fileItems(from: items)

        #expect(voice.map(\.attachment.fileName) == ["note.m4a"])
        #expect(files.map(\.attachment.fileName) == ["notes.pdf"])
    }

    @Test func itemsCarryTheirOwningMessageForJumpNavigation() {
        let items = GroupSharedMediaPresentation.items(from: [
            libraryMediaRecord("message-a", mediaType: "image/jpeg", fileName: "a.jpg", timestamp: 5)
        ])

        #expect(items.first?.messageIdHex == "message-a")
    }

    @Test func groupsItemsIntoMonthSectionsPreservingNewestFirstOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        // 2026-06-15 and 2026-06-01 share a section; 2026-05-20 gets its own;
        // an undated item collects in a trailing section.
        let items = GroupSharedMediaPresentation.items(from: [
            libraryMediaRecord("a", mediaType: "image/jpeg", fileName: "a.jpg", timestamp: 1781740800),
            libraryMediaRecord("b", mediaType: "image/jpeg", fileName: "b.jpg", timestamp: 1780531200),
            libraryMediaRecord("c", mediaType: "image/jpeg", fileName: "c.jpg", timestamp: 1779580800),
            libraryMediaRecord("d", mediaType: "image/jpeg", fileName: "d.jpg", timestamp: 0),
        ])

        let sections = SharedMediaLibraryPresentation.monthSections(
            items,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(sections.count == 3)
        #expect(sections[0].items.map(\.attachment.fileName) == ["a.jpg", "b.jpg"])
        #expect(sections[0].title == "June 2026")
        #expect(sections[1].items.map(\.attachment.fileName) == ["c.jpg"])
        #expect(sections[2].items.map(\.attachment.fileName) == ["d.jpg"])
    }

    private func record(
        _ messageIdHex: String,
        kind: UInt64,
        content: String,
        at timelineAt: UInt64
    ) -> SharedMediaLibraryPresentation.LinkScanRecord {
        SharedMediaLibraryPresentation.LinkScanRecord(
            messageIdHex: messageIdHex,
            kind: kind,
            content: content,
            timelineAt: timelineAt
        )
    }
}

private func libraryMediaRecord(
    _ messageID: String,
    mediaType: String,
    fileName: String,
    timestamp: UInt64
) -> MediaRecordFfi {
    let hashSeed = String(messageID.utf8.reduce(0) { $0 &+ UInt64($1) }, radix: 16)
    let hash = String(repeating: "0", count: max(0, 64 - hashSeed.count)) + hashSeed
    return MediaRecordFfi(
        messageIdHex: messageID,
        attachmentIndex: 0,
        direction: "received",
        groupIdHex: String(repeating: "ab", count: 32),
        sender: String(repeating: "cd", count: 32),
        reference: MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/media")],
            ciphertextSha256: String(repeating: "1", count: 64),
            plaintextSha256: hash,
            nonceHex: String(repeating: "2", count: 24),
            fileName: fileName,
            mediaType: mediaType,
            version: .v1,
            sourceEpoch: 1,
            dim: nil,
            thumbhash: nil
        ),
        caption: nil,
        recordedAt: timestamp,
        receivedAt: timestamp
    )
}

extension SharedMediaLibraryPresentationTests {
    @Test func monthSectionsDoNotReorderNonMonotonicDisplayDates() {
        let june = GroupSharedMediaPresentation.items(from: [
            libraryMediaRecord("june", mediaType: "image/jpeg", fileName: "june.jpg", timestamp: 1781740800)
        ])[0]
        let may = GroupSharedMediaPresentation.items(from: [
            libraryMediaRecord("may", mediaType: "image/jpeg", fileName: "may.jpg", timestamp: 1779580800)
        ])[0]
        let laterJune = GroupSharedMediaPresentation.items(from: [
            libraryMediaRecord("later-june", mediaType: "image/jpeg", fileName: "later.jpg", timestamp: 1780531200)
        ])[0]
        let canonical = [june, may, laterJune]
        let sections = SharedMediaLibraryPresentation.monthSections(canonical)
        #expect(sections.flatMap(\.items).map(\.id) == canonical.map(\.id))
        #expect(Set(sections.map(\.id)).count == sections.count)
    }
}
