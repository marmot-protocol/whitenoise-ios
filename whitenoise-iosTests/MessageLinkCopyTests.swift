import Testing
import CoreGraphics
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct MessageLinkCopyTests {

    private func blocks(_ inlines: [MarkdownInlineFfi]) throws -> [MarkdownDisplayBlock] {
        try #require(MarkdownMessageBuilder.displayBlocks(
            for: MarkdownDocumentFfi(blocks: [.paragraph(inlines: inlines)], truncated: false)
        ))
    }

    private func paragraph(_ inlines: [MarkdownInlineFfi]) throws -> AttributedString {
        guard case .paragraph(let text) = try #require(try blocks(inlines).first) else {
            Issue.record("expected paragraph")
            return AttributedString()
        }
        return text
    }

    private func url(_ raw: String) throws -> URL {
        try #require(URL(string: raw))
    }

    @Test func autolinkCopiesItsDestination() throws {
        let targets = MessageLinkTarget.targets(in: try blocks([
            .text(content: "see "),
            .autolink(url: "www.example.com/path", kind: .www, classification: .web),
        ]))

        #expect(targets.map(\.copyText) == ["https://www.example.com/path"])
    }

    @Test func explicitLabelLinkCopiesDestinationNotLabel() throws {
        let text = try paragraph([
            .text(content: "read "),
            .link(dest: "https://example.com/article", title: nil, children: [.text(content: "this post")], classification: .web),
            .text(content: " later"),
        ])

        let segments = MessageLinkSegment.segments(of: text)
        #expect(segments.map { String($0.text.characters) } == ["read ", "this post", " later"])
        #expect(segments.map(\.target?.copyText) == [nil, "https://example.com/article", nil])
        #expect(MessageLinkTarget.targets(in: [.paragraph(text)]).map(\.copyText) == ["https://example.com/article"])
    }

    @Test func linksInsideQuotesAndListsAreFoundInTraversalOrder() throws {
        let quoted = try paragraph([
            .autolink(url: "https://quote.example.com", kind: .uri, classification: .web),
        ])
        let listed = try paragraph([
            .autolink(url: "https://list.example.com", kind: .uri, classification: .web),
        ])
        let nested: [MarkdownDisplayBlock] = [
            .blockQuote([.paragraph(quoted)]),
            .list(items: [MarkdownDisplayListItem(marker: .bullet, blocks: [.heading(listed)])], tight: true),
        ]

        #expect(MessageLinkTarget.targets(in: nested).map(\.copyText)
            == ["https://quote.example.com", "https://list.example.com"])
    }

    @Test func rejectedDestinationsAreNeverCopyable() throws {
        #expect(MessageLinkTarget.targets(in: try blocks([
            .link(dest: "javascript:alert(1)", title: nil, children: [.text(content: "label")], classification: .dangerous),
        ])).isEmpty)

        let blockedByPolicy = try paragraph([
            .link(dest: "\(DeepLink.scheme)://chat/abc", title: nil, children: [.text(content: "chat")], classification: .web),
        ])
        #expect(blockedByPolicy.runs.first?.link != nil)
        #expect(MessageLinkSegment.segments(of: blockedByPolicy).allSatisfy { $0.target == nil })
        #expect(MessageLinkTarget.targets(in: [.paragraph(blockedByPolicy)]).isEmpty)

        #expect(MessageLinkPolicy.copyText(for: try url("ftp://host/x")) == nil)
        #expect(MessageLinkPolicy.copyText(for: try url("https://example.com")) == "https://example.com")
    }

    @Test func noLinksMeansNoTargets() throws {
        #expect(MessageLinkTarget.targets(in: try blocks([.text(content: "plain words")])).isEmpty)
        #expect(MessageLinkTarget.targets(in: nil).isEmpty)
    }

    @Test func accessibilityOffersOneCopyActionPerDistinctLink() throws {
        let targets = MessageLinkTarget.targets(in: try blocks([
            .autolink(url: "https://example.com", kind: .uri, classification: .web),
            .text(content: " and "),
            .link(dest: "https://example.com", title: nil, children: [.text(content: "again")], classification: .web),
            .text(content: " and "),
            .autolink(url: "a@b.com", kind: .email, classification: .contact),
        ]))

        #expect(targets.map(\.copyText) == ["https://example.com", "mailto:a@b.com"])
        #expect(MessageLinkTarget.accessibilityActionTitles(for: targets) == [
            L10n.formatted("Copy Link: %@", "example.com"),
            L10n.formatted("Copy Link: %@", "mailto:a@b.com"),
        ])

        let single = try #require(MessageLinkTarget(url: try url("https://example.com")))
        #expect(MessageLinkTarget.accessibilityActionTitles(for: [single]) == [L10n.string("Copy Link")])
    }

    @Test func sameHostLinksGetDistinctAccessibilityTitles() throws {
        let targets = try [
            "https://example.com/a?x=1",
            "https://example.com/b",
            "https://example.com/",
        ].map { try #require(MessageLinkTarget(url: try url($0))) }

        #expect(MessageLinkTarget.accessibilityActionTitles(for: targets) == [
            L10n.formatted("Copy Link: %@", "example.com/a?x=1"),
            L10n.formatted("Copy Link: %@", "example.com/b"),
            L10n.formatted("Copy Link: %@", "example.com"),
        ])
    }

    @Test func truncatedTitlesThatCollideAreNumbered() throws {
        let middle = String(repeating: "m", count: 100)
        let targets = try [
            "https://example.com/start\(middle)1\(middle)end",
            "https://example.com/start\(middle)2\(middle)end",
        ].map { try #require(MessageLinkTarget(url: try url($0))) }

        #expect(targets[0].displayText == targets[1].displayText)
        let titles = MessageLinkTarget.accessibilityActionTitles(for: targets)
        #expect(titles == [
            L10n.formatted("Copy Link: %@", "\(targets[0].displayText) (1)"),
            L10n.formatted("Copy Link: %@", "\(targets[1].displayText) (2)"),
        ])
        #expect(targets.map(\.copyText) == [
            "https://example.com/start\(middle)1\(middle)end",
            "https://example.com/start\(middle)2\(middle)end",
        ])
    }

    @Test func longPressRegionsCoverOnlyActionableLinkRuns() throws {
        let link = try url("https://example.com")
        let regions = MessageLinkHitRegion.regions(from: [
            (url: nil, rect: CGRect(x: 0, y: 0, width: 40, height: 20)),
            (url: link, rect: CGRect(x: 40, y: 0, width: 30, height: 20)),
            (url: try url("\(DeepLink.scheme)://chat/abc"), rect: CGRect(x: 70, y: 0, width: 30, height: 20)),
            (url: nil, rect: CGRect(x: 100, y: 0, width: 40, height: 20)),
        ])

        #expect(regions.map(\.rect) == [CGRect(x: 40, y: 0, width: 30, height: 20)])
        #expect(regions.map(\.target.copyText) == ["https://example.com"])
    }

    @Test func longPressRegionsMergeStyledRunsAndSplitWrappedLines() throws {
        let link = try url("https://example.com")
        let regions = MessageLinkHitRegion.regions(from: [
            (url: link, rect: CGRect(x: 40, y: 0, width: 30, height: 20)),
            (url: link, rect: CGRect(x: 70, y: 0, width: 20, height: 20)),
            (url: link, rect: CGRect(x: 0, y: 20, width: 25, height: 20)),
            (url: link, rect: .zero),
        ])

        #expect(regions.map(\.rect) == [
            CGRect(x: 40, y: 0, width: 50, height: 20),
            CGRect(x: 0, y: 20, width: 25, height: 20),
        ])
    }
}
