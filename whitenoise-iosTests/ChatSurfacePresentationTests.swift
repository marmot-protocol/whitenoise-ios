import CoreGraphics
import Foundation
import Testing
import SwiftUI
import UIKit
@testable import whitenoise_ios

@MainActor
struct ChatSurfacePresentationTests {
    @Test func reportActionMenuFitsSmallScreensAndRetainsScrollableActions() {
        let count = MessageActionsPresentation.actionCount(canRetry: false, canInteract: true,
            canForward: true, canEdit: true, canViewEditHistory: true, canDelete: true, canReport: true)
        let height = MessageActionsPresentation.visibleActionHeight(actionCount: count,
            containerHeight: 568, showsReactions: true)
        let layout = MessageActionsOverlayLayout.resolve(sourceFrame: CGRect(x: 20, y: 200, width: 200, height: 100),
            containerHeight: 568, actionMenuHeight: height, showsReactions: true)
        #expect(height < MessageActionsPresentation.actionMenuHeight(actionCount: count))
        #expect(layout.groupTop >= 0)
        #expect(layout.groupTop + layout.groupHeight <= 568)
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func confirmationKeepsDeliveryFooterSizeStable(dynamicType: DynamicTypeSize) {
        func size(_ status: MessageStatus) -> CGSize {
            let host = UIHostingController(rootView: MessageMetadataFooter(
                time: "12:34", isEdited: false, status: status, isFromMe: true
            ).environment(\.dynamicTypeSize, dynamicType))
            return host.sizeThatFits(in: CGSize(width: 300, height: 100))
        }
        let pending = size(.sending)
        let confirmed = size(.sent)
        #expect(abs(pending.height - confirmed.height) < 0.1)
        #expect(abs(pending.width - confirmed.width) < 0.1)
    }

    @Test func deliveryFooterUsesCompactSymbols() {
        #expect(MessageFooterPresentation.value(for: .sent, isFromMe: true).systemImage == "checkmark")
        #expect(MessageFooterPresentation.value(for: .sending, isFromMe: true).systemImage == "clock")
        #expect(MessageFooterPresentation.value(for: .failed, isFromMe: true).isFailure)
        #expect(MessageFooterPresentation.value(for: .received, isFromMe: false).systemImage == nil)
    }

    @Test func durablePendingRowsKeepRetryActionAvailable() {
        #expect(MessageRetryPresentation.isAvailable(status: .sending, hasRetryableSend: true))
        #expect(MessageRetryPresentation.isAvailable(status: .failed, hasRetryableSend: true))
        #expect(!MessageRetryPresentation.isAvailable(status: .sent, hasRetryableSend: true))
        #expect(!MessageRetryPresentation.isAvailable(status: .sending, hasRetryableSend: false))
    }

    @Test func mediaUploadIndicatorOnlyAppearsForPendingLocalMedia() {
        let pending = MessageMediaAttachment(
            id: "pending-image",
            reference: nil,
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([1])
        )
        let unresolvedRemote = MessageMediaAttachment(
            id: "remote-image",
            reference: nil,
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: nil
        )

        #expect(MessageMediaUploadPresentation.showsIndicator(status: .sending, items: [pending]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .sent, items: [pending]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .failed, items: [pending]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .sending, items: [unresolvedRemote]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .sending, items: []))
    }

    @Test func reactionSummaryCombinesEmojisAndTotalCount() throws {
        let summary = try #require(ReactionSummaryPresentation.value(from: [
            .init(emoji: "👍", count: 4, mine: false),
            .init(emoji: "❤️", count: 3, mine: true),
            .init(emoji: "😂", count: 2, mine: false),
            .init(emoji: "😮", count: 1, mine: false),
        ]))

        #expect(summary.emojis == ["❤️", "👍", "😂"])
        #expect(summary.totalCount == 10)
        #expect(summary.mine)
        #expect(ReactionSummaryPresentation.value(from: []) == nil)
    }

    @Test func emojiSearchPrefersExactAndPrefixNames() {
        let entries = [
            EmojiCatalogEntry(emoji: "😂", name: "face with tears of joy", group: 0, keywords: ["laugh"]),
            EmojiCatalogEntry(emoji: "😊", name: "smiling face", group: 0, keywords: ["happy"]),
            EmojiCatalogEntry(emoji: "❤️", name: "red heart", group: 7, keywords: ["love"]),
        ]

        #expect(EmojiCatalogSearch.results(in: entries, query: "smiling").map(\.emoji) == ["😊"])
        #expect(EmojiCatalogSearch.results(in: entries, query: "love").map(\.emoji) == ["❤️"])
        #expect(EmojiCatalogSearch.results(in: entries, query: "face joy").map(\.emoji) == ["😂"])
    }

    @Test func emojiCatalogDecodingPrecomputesCaseInsensitiveSearchTerms() throws {
        let data = Data(#"[{"e":"x","n":"Smiling FACE","g":0,"k":["HAPPY","Joy"]}]"#.utf8)
        let entry = try #require(JSONDecoder().decode([EmojiCatalogEntry].self, from: data).first)

        #expect(entry.nameLowercased == "smiling face")
        #expect(entry.keywordsLowercased == ["happy", "joy"])
        #expect(EmojiCatalogSearch.results(in: [entry], query: "FACE joy") == [entry])
    }

    @Test func timelineDaySectionsReuseGenerationAndInvalidateForCalendarContext() {
        let cache = ConversationDaySectionProjectionCache()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let items = [
            TimelineItem.systemEvent(id: "1", event: .groupCreated, timestamp: 86_400),
            TimelineItem.systemEvent(id: "2", event: .rosterChanged, timestamp: 86_401),
            TimelineItem.systemEvent(id: "3", event: .groupArchived, timestamp: 172_800),
        ]

        let first = cache.sections(for: items, generation: 1, calendar: calendar, locale: locale)
        let cached = cache.sections(for: items, generation: 1, calendar: calendar, locale: locale)
        #expect(first == cached)
        #expect(first.map(\.items.count) == [2, 1])
        #expect(cache.buildCountForTesting == 1)

        calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
        _ = cache.sections(for: items, generation: 1, calendar: calendar, locale: locale)
        _ = cache.sections(
            for: items,
            generation: 1,
            calendar: calendar,
            locale: Locale(identifier: "fr_FR")
        )
        _ = cache.sections(for: items, generation: 2, calendar: calendar, locale: locale)
        #expect(cache.buildCountForTesting == 4)
    }

    @Test func mediaGridHandlesOneThroughOverflowWithoutMoreThanFiveTiles() {
        for count in 1...8 {
            let visible = MessageMediaGridPresentation.visibleCount(totalCount: count)
            let columns = MessageMediaGridPresentation.columnCount(totalCount: count)
            let rows = MessageMediaGridPresentation.rowCount(totalCount: count)
            #expect(visible <= 5)
            #expect(rows * columns >= visible)
            #expect(MessageMediaGridPresentation.hiddenCount(totalCount: count) == max(0, count - 5))
        }
    }

    @Test func compactBubblesReserveReadableOppositeMargin() {
        #expect(ChatBubbleMetrics.compactOppositeInset >= 44)
        #expect(ChatBubbleMetrics.regularMaximumWidth == 560)
    }

    @Test func singleEmojiMessagesUseStickerPresentation() {
        #expect(SingleEmojiMessagePresentation.emoji(in: "😀") == "😀")
        #expect(SingleEmojiMessagePresentation.emoji(in: "  ❤️\n") == "❤️")
        #expect(SingleEmojiMessagePresentation.emoji(in: "👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦")
        #expect(SingleEmojiMessagePresentation.emoji(in: "👍🏽") == "👍🏽")
        #expect(SingleEmojiMessagePresentation.emoji(in: "1️⃣") == "1️⃣")
        #expect(SingleEmojiMessagePresentation.emoji(in: "🇮🇹") == "🇮🇹")
        #expect(SingleEmojiMessagePresentation.fontSize >= 56)
    }

    @Test func stickerPresentationRejectsTextAndMultipleEmoji() {
        #expect(SingleEmojiMessagePresentation.emoji(in: "") == nil)
        #expect(SingleEmojiMessagePresentation.emoji(in: "A") == nil)
        #expect(SingleEmojiMessagePresentation.emoji(in: "1") == nil)
        #expect(SingleEmojiMessagePresentation.emoji(in: "©") == nil)
        #expect(SingleEmojiMessagePresentation.emoji(in: "😀😀") == nil)
        #expect(SingleEmojiMessagePresentation.emoji(in: "😀 hello") == nil)
        #expect(SingleEmojiMessagePresentation.emoji(in: "\u{FE0F}") == nil)
    }

    @Test func disappearingMessageIndicatorRequiresFiniteActiveExpiry() {
        #expect(MessageExpirationPresentation.showsIndicator(
            retentionSeconds: 300,
            expiresAt: 1_700_000_300
        ))
        #expect(!MessageExpirationPresentation.showsIndicator(
            retentionSeconds: nil,
            expiresAt: 1_700_000_300
        ))
        #expect(!MessageExpirationPresentation.showsIndicator(
            retentionSeconds: 0,
            expiresAt: nil
        ))
        #expect(!MessageExpirationPresentation.showsIndicator(
            retentionSeconds: 300,
            expiresAt: nil
        ))
        #expect(MessageExpirationPresentation.systemImage == "timer")
    }

    @Test func expirationDetailUsesRelativeTimeForTheNextDayThenAnExactDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nearDate = now.addingTimeInterval(5 * 60)
        let boundaryDate = now.addingTimeInterval(MessageExpirationPresentation.relativeTimeHorizon)
        let farDate = now.addingTimeInterval(MessageExpirationPresentation.relativeTimeHorizon + 1)

        #expect(MessageExpirationPresentation.detail(expiresAt: nil, now: now) == nil)
        #expect(MessageExpirationPresentation.detail(
            expiresAt: UInt64(now.timeIntervalSince1970),
            now: now
        ) == .expired)
        #expect(MessageExpirationPresentation.detail(
            expiresAt: UInt64(nearDate.timeIntervalSince1970),
            now: now
        ) == .relative(nearDate))
        #expect(MessageExpirationPresentation.detail(
            expiresAt: UInt64(boundaryDate.timeIntervalSince1970),
            now: now
        ) == .relative(boundaryDate))
        #expect(MessageExpirationPresentation.detail(
            expiresAt: UInt64(farDate.timeIntervalSince1970),
            now: now
        ) == .absolute(farDate))
    }

    @Test func multiMessageSelectionUsesSharedForwardLimitAndStrictDeleteCapability() {
        #expect(MessageSelectionPolicy.canForward(selectedCount: 1, anyForwardable: true))
        #expect(MessageSelectionPolicy.canForward(selectedCount: 30, anyForwardable: true))
        #expect(!MessageSelectionPolicy.canForward(selectedCount: 31, anyForwardable: true))
        #expect(!MessageSelectionPolicy.canForward(selectedCount: 2, anyForwardable: false))
        #expect(!MessageSelectionPolicy.canForward(selectedCount: 0, anyForwardable: true))
        #expect(MessageSelectionPolicy.canDelete(selectedCount: 2, allDeletable: true))
        #expect(!MessageSelectionPolicy.canDelete(selectedCount: 2, allDeletable: false))
    }

    @Test func messageActionPanelHeightTracksOnlyVisibleRows() {
        let compactCount = MessageActionsPresentation.actionCount(
            canRetry: false,
            canInteract: false,
            canForward: false,
            canEdit: false,
            canViewEditHistory: false,
            canDelete: false
        )
        let expandedCount = MessageActionsPresentation.actionCount(
            canRetry: true,
            canInteract: true,
            canForward: true,
            canEdit: true,
            canViewEditHistory: true,
            canDelete: true
        )

        #expect(compactCount == 3)
        #expect(expandedCount == 9)
        #expect(MessageActionsPresentation.actionMenuHeight(actionCount: expandedCount)
            == 9 * MessageActionsPresentation.actionHeight
                + MessageActionsPresentation.actionVerticalPadding * 2)
    }

    @Test func reactionSurfaceCanBeWiderThanTheActionPanelWithoutLeavingScreenMargins() {
        let sixReactionsAndMore = MessageActionsPresentation.reactionWidth(
            itemCount: 7,
            maximumWidth: 358
        )
        let selectedReactionPlusMore = MessageActionsPresentation.reactionWidth(
            itemCount: 8,
            maximumWidth: 358
        )

        #expect(sixReactionsAndMore == 320)
        #expect(sixReactionsAndMore > MessageActionsPresentation.menuWidth)
        #expect(selectedReactionPlusMore == 358)
    }

    @Test func conversationDateHeadersCategorizeTodayYesterdayAndOlderDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_721_174_400)
        let today = UInt64(now.timeIntervalSince1970)
        let yesterday = UInt64(calendar.date(byAdding: .day, value: -1, to: now)!.timeIntervalSince1970)
        let older = UInt64(calendar.date(byAdding: .day, value: -4, to: now)!.timeIntervalSince1970)

        #expect(ConversationDateHeader.label(timestamp: today, now: now, calendar: calendar) == "Today")
        #expect(ConversationDateHeader.label(timestamp: yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(ConversationDateHeader.label(timestamp: older, now: now, calendar: calendar) != "Today")
        #expect(ConversationDateHeader.label(timestamp: older, now: now, calendar: calendar) != "Yesterday")
    }

    @Test func composerShowsExpandedEditorForLongOrMultilineDrafts() {
        #expect(!ComposerExpandedEditorPresentation.shouldShowExpandButton(for: "Short"))
        #expect(!ComposerExpandedEditorPresentation.shouldShowExpandButton(for: ""))
        #expect(ComposerExpandedEditorPresentation.shouldShowExpandButton(for: "Short\n"))
        #expect(ComposerExpandedEditorPresentation.shouldShowExpandButton(for: "\n"))
        #expect(ComposerExpandedEditorPresentation.shouldShowExpandButton(for: "Short\r\nsecond line"))
        #expect(ComposerExpandedEditorPresentation.shouldShowExpandButton(
            for: String(repeating: "a", count: ComposerExpandedEditorPresentation.minimumExpandCharacterCount)
        ))
        #expect(ComposerExpandedEditorPresentation.shouldShowExpandButton(for: "one\ntwo\nthree\nfour"))
    }

    @Test func cappedComposerTextInputEnablesInternalScrollingForLongDrafts() {
        let textView = ImagePasteTextView(
            frame: CGRect(x: 0, y: 0, width: 240, height: 112)
        )
        textView.font = .systemFont(ofSize: 18)
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false

        textView.text = "Short"
        let shortHeight = textView.updateScrollability(
            maximumHeight: 112,
            fittingWidth: textView.bounds.width,
            revealSelection: false
        )
        #expect(shortHeight < 112)
        #expect(!textView.isScrollEnabled)

        textView.text = (1 ... 8).map { "Line \($0)" }.joined(separator: "\n")
        let longHeight = textView.updateScrollability(
            maximumHeight: 112,
            fittingWidth: textView.bounds.width,
            revealSelection: true
        )
        #expect(longHeight > 112)
        #expect(textView.isScrollEnabled)

        let repeatedLongHeight = textView.updateScrollability(
            maximumHeight: 112,
            fittingWidth: textView.bounds.width,
            revealSelection: false
        )
        #expect(repeatedLongHeight > 112)
        #expect(textView.isScrollEnabled)

        textView.text = "Short again"
        _ = textView.updateScrollability(
            maximumHeight: 112,
            fittingWidth: textView.bounds.width,
            revealSelection: false
        )
        #expect(!textView.isScrollEnabled)
    }

    @Test func sharedLocationUsesCanonicalGoogleMapsURLCoordinates() {
        #expect(
            SharedLocationText.value(latitude: 9.0765, longitude: 7.3986)
                == "https://www.google.com/maps/search/?api=1&query=9.076500%2C7.398600"
        )
    }

    @Test func sharedLocationRecognizesGoogleAndLegacyAppleMapURLs() throws {
        let google = try #require(SharedLocationText.location(
            from: "https://www.google.com/maps/search/?api=1&query=9.076500%2C7.398600"
        ))
        #expect(google.latitude == 9.0765)
        #expect(google.longitude == 7.3986)
        #expect(google.url.host == "www.google.com")

        let apple = try #require(SharedLocationText.location(
            from: "https://maps.apple.com/?ll=-33.856800,151.215300"
        ))
        #expect(apple.latitude == -33.8568)
        #expect(apple.longitude == 151.2153)
        #expect(apple.url.host == "maps.apple.com")
    }

    @Test func sharedLocationRejectsNonCanonicalOrInvalidMapURLs() {
        let invalidValues = [
            "Meet here: https://www.google.com/maps/search/?api=1&query=9.0%2C7.0",
            "https://www.google.com.evil.example/maps/search/?api=1&query=9.0%2C7.0",
            "https://www.google.com/maps/search/?query=9.0%2C7.0",
            "https://www.google.com/maps/search/?api=1&query=91.0%2C7.0",
            "https://www.google.com/maps/search/?api=1&query=9.0%2C7.0&query",
            "https://maps.apple.com/?ll=9.0,181.0",
            "https://maps.apple.com/place?ll=9.0,7.0",
        ]

        for value in invalidValues {
            #expect(SharedLocationText.location(from: value) == nil)
        }
    }
}
