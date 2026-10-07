import Foundation
import SwiftUI
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct MarkdownTimestampTests {
    @Test func cachedTimestampRetainsStyleAndLinkedEmphasis() throws {
        let document = MarkdownDocumentFfi(blocks: [.paragraph(inlines: [
            .link(dest: "https://example.com", title: nil, children: [
                .strong(children: [.timestamp(unixSeconds: -1, style: .relative)])
            ], classification: .web)
        ])], truncated: false)
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: document))
        guard case .paragraph(let source) = blocks[0] else { Issue.record("Missing paragraph"); return }
        let run = try #require(source.runs.first)
        #expect(run[MarkdownTimestampAttribute.self] == MarkdownTimestamp(unixSeconds: -1, style: .relative))
        #expect(run.link == URL(string: "https://example.com"))
        #expect(run.font == Font.body.bold())
        #expect(String(source.characters) == "<t:-1:R>")
        #expect(MarkdownTimestamp.plainText(source, now: Date(timeIntervalSince1970: -61))
            != MarkdownTimestamp.plainText(source, now: Date(timeIntervalSince1970: 59)))
        #expect(String(source.characters) == "<t:-1:R>")
    }

    @Test func previewProjectionRetainsTimestampAndCodeLiteral() throws {
        let document = MarkdownDocumentFfi(blocks: [.paragraph(inlines: [
            .timestamp(unixSeconds: 60, style: .relative), .code(content: "<t:60:R>")
        ])], truncated: false)
        let source = try #require(MarkdownPlainText.timestampProjection(document))
        let timestamps = source.runs.compactMap { $0[MarkdownTimestampAttribute.self] }
        #expect(timestamps == [MarkdownTimestamp(unixSeconds: 60, style: .relative)])
        let first = MarkdownTimestamp.plainText(source, now: Date(timeIntervalSince1970: 0))
        let second = MarkdownTimestamp.plainText(source, now: Date(timeIntervalSince1970: 120))
        #expect(first != second)
        #expect(first.hasSuffix("<t:60:R>"))
        #expect(second.hasSuffix("<t:60:R>"))
    }

    @Test func identicalAdjacentTimestampsRemainSeparateOccurrences() throws {
        let document = MarkdownDocumentFfi(blocks: [.paragraph(inlines: [
            .timestamp(unixSeconds: 0, style: .shortTime),
            .timestamp(unixSeconds: 0, style: .shortTime)
        ])], truncated: false)
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: document))
        guard case .paragraph(let source) = blocks[0] else { Issue.record("Missing paragraph"); return }
        #expect(source.runs.compactMap { $0[MarkdownTimestampAttribute.self] }.count == 2)
        #expect(Set(source.runs.compactMap { $0[MarkdownTimestampOccurrenceAttribute.self] }).count == 2)
    }

    @Test func stylesTimezoneAndSignedEpoch() {
        let locale = Locale(identifier: "en_US")
        let utc = TimeZone(secondsFromGMT: 0)!
        for style in MarkdownTimestamp.Style.allCases {
            let timestamp = MarkdownTimestamp(unixSeconds: -1, style: style)
            #expect(!timestamp.label(now: Date(timeIntervalSince1970: 0), locale: locale, timeZone: utc).isEmpty)
            #expect(timestamp.disclosure(locale: locale, timeZone: utc).hasSuffix(timestamp.token))
        }
        let timestamp = MarkdownTimestamp(unixSeconds: -1, style: .compactDateTimeSeconds)
        #expect(timestamp.label(locale: locale, timeZone: utc)
            != timestamp.label(locale: locale, timeZone: TimeZone(secondsFromGMT: 3600)!))
    }

    @Test func extremeEpochsNeverOverflowRelativeOrLoseCanonicalSeconds() {
        let minimum = MarkdownTimestamp(unixSeconds: .min, style: .relative)
        let maximum = MarkdownTimestamp(unixSeconds: .max, style: .relative)
        #expect(minimum.relativeComponents(now: Date(timeIntervalSince1970: 0)).year == -292_471_208_677)
        #expect(maximum.relativeComponents(now: Date(timeIntervalSince1970: Double(Int64.min))).year == 584_942_417_355)
        for seconds in [Int64.min, Int64.max] {
            let timestamp = MarkdownTimestamp(unixSeconds: seconds, style: .relative)
            #expect(timestamp.token == "<t:\(seconds):R>")
            #expect(!timestamp.label(now: Date(timeIntervalSince1970: 0)).isEmpty)
            #expect(timestamp.disclosure().hasSuffix(timestamp.token))
        }
    }
}
