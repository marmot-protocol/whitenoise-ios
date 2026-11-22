#if DEBUG
import Foundation
import MarmotKit

extension ChatPreviewThread {
    // Synthetic keys preserve the prototype’s author colours through the production palette.
    static let elias = String(repeating: "81", count: 32)
    static let nora = String(repeating: "87", count: 32)
    static let referenceLeo = String(repeating: "85", count: 32)
    private static let referencePeople = [(owner, "Marmota"), (peer, "Maya Chen"), (elias, "Elias Moreno"), (nora, "Nora Bennett")]
    private static let referenceNow = Date(timeIntervalSince1970: TimeInterval(catalogTime))

    private static func day(_ daysAgo: Int, hour: Int) -> Date {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: referenceNow)!
        let opening = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        // Leave room for the longest same-day sequence before a newly sent preview message.
        return daysAgo == 0 ? min(opening, referenceNow.addingTimeInterval(-601)) : opening
    }

    static var referenceExamples: [Self] {
        [referenceText, referenceGroup, referenceReactions, referenceReplies, referenceGallery,
         referenceSingles, referenceViewer, referenceDates, referenceColors, referenceAttachments,
         referenceEvents, referenceLeftGroup, referenceMaya, referenceWeekend]
    }

    private static var referenceText: Self {
        let priorYear = Calendar.current.date(byAdding: .year, value: -1, to: referenceNow)!
        let sameYear = day(30, hour: 9)
        let weekday = day(4, hour: 10)
        let yesterday = day(1, hour: 11)
        let today = day(0, hour: 8)
        let formatted: [MarkdownBlockFfi] = [.paragraph(inlines: [
            .text(content: "TXT-09: "), .strong(children: [.text(content: "Bold")]), .text(content: ", "),
            .emph(children: [.text(content: "emphasis")]), .text(content: ", and "),
            .link(dest: whiteNoiseURL.absoluteString, title: nil, children: [.text(content: "White Noise")], classification: .web)
        ])]
        let guidance: [MarkdownBlockFfi] = [.paragraph(inlines: [
            .text(content: "TXT-10: "), .link(dest: designURL.absoluteString, title: nil,
                children: [.text(content: designURL.absoluteString)], classification: .web)
        ])]
        return Self(21, "Direct - Text & Delivery", direct: true, [
            .init("TXT-01: Incoming short text", at: priorYear),
            .init("TXT-02: Outgoing short text", by: owner, at: sameYear),
            .init("TXT-03: Cluster start", at: weekday),
            .init("TXT-04: Cluster middle", at: weekday + 60),
            .init("TXT-05: Cluster end", at: weekday + 120),
            .init("CLUSTER-01: Author change starts a new cluster", by: owner, at: weekday + 180),
            .init("CLUSTER-02: More than five minutes starts a new cluster", by: owner, at: weekday + 600),
            .init("TXT-06: Multiline text\nSecond line\nThird line", at: yesterday),
            .init("TXT-07: Long wrapping text demonstrates how a message bubble grows across several lines while preserving readable padding and alignment at both edges of the conversation.", by: owner, at: yesterday + 90),
            .init("TXT-08: 👋🏽🎉", at: yesterday + 180),
            .init("CLUSTER-03: A new day starts a new cluster", at: today),
            .init("TXT-09: **Bold**, *emphasis*, and [White Noise](https://whitenoise.chat)", .markdown(formatted), by: owner, at: today + 60),
            .init("TXT-10: https://developer.apple.com/design/human-interface-guidelines", .markdown(guidance), at: today + 120),
            .init("DLV-01: Sending outgoing message", .pending, by: owner, at: today + 180),
            .init("DLV-02: Sent outgoing message", by: owner, at: today + 240),
            .init("DLV-03: Failed outgoing message", .failed, by: owner, at: today + 600),
        ])
    }

    private static var referenceGroup: Self {
        let old = day(9, hour: 9)
        let yesterday = day(1, hour: 10)
        let today = day(0, hour: 9)
        return Self(22, "Group - Messages & Mentions", people: referencePeople, [
            .init("GRP-01: Incoming group cluster start", at: old + 180),
            .init("GRP-02: Same-author cluster end", at: old + 240),
            .init("GRP-03: Author switch", by: elias, at: old + 300),
            .init("GRP-04: Outgoing interruption", by: owner, at: old + 360),
            .init("GRP-05: Five-minute cluster break", by: elias, at: old + 720),
            .init("MENTION-01: @Marmota please review this.", .namedMentions([("Marmota", owner)]), at: yesterday),
            .init("MENTION-02: @Maya Chen has the latest version.", .namedMentions([("Maya Chen", peer)]), by: owner, at: yesterday + 120),
            .init("MENTION-03: @Maya Chen and @Elias Moreno can compare notes.", .namedMentions([("Maya Chen", peer), ("Elias Moreno", elias)]), by: nora, at: yesterday + 240),
            .init("MENTION-04: @Unknown stays plain text.", by: elias, at: yesterday + 360),
            .init("GRP-RPL-01 source: Maya’s question", at: today),
            .init("GRP-RPL-01: Elias replies to Maya", .reply(9), by: elias, at: today + 60),
            .init("GRP-RPL-02: Maya replies to Elias", .reply(10), at: today + 120),
            .init("☕️", at: today + 480),
            .init("☕️", by: owner, at: today + 540),
        ])
    }

    private static var referenceReactions: Self {
        let start = referenceNow - 9_000
        let overflow = ["❤", "😀", "👍", "👎", "🤣", "🔥", "🦫"].enumerated().map { index, emoji in
            (emoji, index.isMultiple(of: 2) ? [peer] : [owner, peer])
        }
        return Self(23, "Direct - Reactions & Actions", direct: true, people: referencePeople, [
            .init("RCT-01: Single reaction from another person", .reactionParticipants([("❤", [peer])]), at: start),
            .init("RCT-02: You reacted", .reactionParticipants([("😀", [owner])]), by: owner, at: start + 60),
            .init("RCT-03: Repeated reaction from three others", .reactionParticipants([("👍", [peer, elias, nora])]), at: start + 120),
            .init("RCT-04: Repeated reaction including you", .reactionParticipants([("👎", [owner, peer, elias])]), by: owner, at: start + 180),
            .init("RCT-05: Mixed reaction types and participation", .reactionParticipants([("🤣", [owner]), ("🔥", [peer, elias]), ("🦫", [owner, peer, nora])]), at: start + 240),
            .init("RCT-6: Supported reaction ❤", .reactionParticipants([("❤", [peer])]), at: start + 360),
            .init("RCT-7: Supported reaction 😀", .reactionParticipants([("😀", [peer])]), by: owner, at: start + 420),
            .init("RCT-8: Supported reaction 👍", .reactionParticipants([("👍", [peer])]), at: start + 480),
            .init("RCT-9: Supported reaction 👎", .reactionParticipants([("👎", [peer])]), by: owner, at: start + 540),
            .init("RCT-10: Supported reaction 🤣", .reactionParticipants([("🤣", [peer])]), at: start + 600),
            .init("RCT-11: Supported reaction 🔥", .reactionParticipants([("🔥", [peer])]), by: owner, at: start + 660),
            .init("RCT-12: Supported reaction 🦫", .reactionParticipants([("🦫", [peer])]), at: start + 720),
            .init("RCT-13: Overflow summary", .reactionParticipants(overflow), by: owner, at: start + 780),
            .init("ACT-01: Incoming text: React, Reply, Copy, Share", at: start + 900),
            .init("ACT-02: Outgoing text: React, Reply, Copy, Share, Delete", by: owner, at: start + 960),
            .init("ACT-03 → next bubble: Incoming attachment-only: no Copy or Delete", by: owner, at: start + 1_080),
            .init("", .media(["badger.jpg"]), at: start + 1_140),
            .init("ACT-04 → next bubble: Outgoing attachment-only: Delete, no Copy", at: start + 1_260),
            .init("", .media(["badger.jpg"]), by: owner, at: start + 1_320),
            .init("ACT-05 → next bubble: Available file shares its file URL", at: start + 1_440),
            .init("", .media(["Project Brief.pdf"]), by: owner, at: start + 1_500),
        ])
    }

    private static var referenceReplies: Self {
        let start = referenceNow - 7_200
        return Self(24, "Direct - Replies & Deletion", direct: true, [
            .init("RPL-01 source: Incoming text", at: start),
            .init("RPL-01: Outgoing reply to incoming text", .reply(0), by: owner, at: start + 60),
            .init("RPL-02-source → next bubble: Outgoing attachment reply target", at: start + 240),
            .init("", .media(["fox.jpg"]), by: owner, at: start + 300),
            .init("RPL-02: Incoming reply to outgoing attachment", .reply(3), at: start + 360),
            .init("DEL-02 → next bubble: Incoming deletion and deleted reply target", by: owner, at: start + 600),
            .init("", .deleted, at: start + 660),
            .init("RPL-03: Reply to deleted target", .reply(6), by: owner, at: start + 720),
            .init("DEL-01 → next bubble: Outgoing deletion", at: start + 900),
            .init("", .deleted, by: owner, at: start + 960),
            .init("RPL-04: Missing reply target", .missingReply, at: start + 1_200),
        ])
    }

    private static var referenceGallery: Self {
        let start = referenceNow - 11_000
        let gallery = ["gallery-portrait.jpg", "fox.jpg", "studio-portrait.jpg", "ostrich.jpg",
                       "satoshi.jpg", "badger.jpg", "outdoor-portrait.jpg", "portrait.jpg"]
        return Self(25, "Media - Gallery Layouts", direct: true, [
            .init("MED-04: Gallery of 2", .media(Array(gallery.prefix(2))), by: owner, at: start),
            .init("MED-05: Gallery of 3", .media(Array(gallery.prefix(3))), at: start + 180),
            .init("MED-06: Gallery of 4", .media(Array(gallery.prefix(4))), by: owner, at: start + 360),
            .init("MED-07: Captioned gallery of 5", .media(Array(gallery.prefix(5))), at: start + 540),
            .init("MED-08: Gallery of 6 with +1", .media(Array(gallery.prefix(6))), by: owner, at: start + 720),
            .init("MED-09: Gallery of 7 with +2", .media(Array(gallery.prefix(7))), at: start + 900),
            .init("MED-10: Mixed photo and video album", .media([gallery[0], "trail-landscape.mp4", gallery[2], gallery[3], gallery[4]]), by: owner, at: start + 1_080),
            .init("MED-GALLERY-08: Larger overflow +3", .media(gallery), at: start + 1_260),
        ])
    }

    private static var referenceSingles: Self {
        let start = referenceNow - 14_000
        return Self(26, "Media - Single Photos & Video", direct: true, [
            .init("MED-01: Incoming landscape", .media(["fox.jpg"]), at: start),
            .init("MED-02: Outgoing square", .media(["portrait-study.jpg"]), by: owner, at: start + 180),
            .init("MED-03: Captioned portrait", .media(["satoshi.jpg"]), at: start + 360),
            .init("MED-SINGLE-04: Panorama ratio clamped", .media(["ostrich-panorama.jpg"]), by: owner, at: start + 540),
            .init("MED-SINGLE-05: Tall ratio clamped", .media(["tall-backdrop.jpg"]), at: start + 720),
            .init("MED-SINGLE-06: Low-resolution safeguard", .media(["small-marmots.jpg"]), by: owner, at: start + 900),
            .init("MED-11: Landscape video with duration", .media(["trail-landscape.mp4"]), at: start + 1_080),
            .init("MED-SINGLE-08: Portrait video", .media(["trail-portrait.mp4"]), by: owner, at: start + 1_260),
            .init("MED-13: Unavailable photo", .media(["Unavailable.jpg"]), at: start + 1_440),
            .init("MED-12: Unavailable video", .media(["Unavailable.mp4"]), by: owner, at: start + 1_620),
        ])
    }

    private static var referenceViewer: Self {
        let dayOne = day(3, hour: 9)
        let dayTwo = day(1, hour: 14)
        let today = day(0, hour: 10)
        return Self(27, "Media - Viewer Actions", direct: true, [
            .init("MED-VIEW-01: Paging starts across dates", .media(["fox.jpg"]), at: dayOne),
            .init("MED-VIEW-02: Zoom and Share", .media(["ostrich.jpg"]), by: owner, at: dayOne + 120),
            .init("MED-VIEW-03: Save and Forward", .media(["badger.jpg"]), at: dayTwo),
            .init("MED-VIEW-04: Initial video autoplays", .media(["trail-landscape.mp4"]), by: owner, at: dayTwo + 120),
            .init("MED-VIEW-05: Go to Message", .media(["marmot.jpg"]), at: today),
            .init("MED-VIEW-06: Deleted media excluded", .deleted, by: owner, at: today + 120),
            .init("MED-VIEW-07: Unavailable media excluded", .media(["Unavailable.jpg"]), at: today + 240),
        ])
    }

    private static var referenceDates: Self {
        let today = day(0, hour: 8)
        return Self(28, "Direct - Dates & Scrolling", direct: true, [
            .init("DATE-01: Old date includes its year", at: day(220, hour: 9)),
            .init("DATE-02: Recent date uses weekday, month, and day", by: owner, at: day(21, hour: 9)),
            .init("DATE-03: First sparse one-message day", at: day(5, hour: 10)),
            .init("DATE-04: Second sparse one-message day", by: owner, at: day(4, hour: 10)),
            .init("DATE-05: Third sparse one-message day", at: day(3, hour: 10)),
            .init("DATE-06: Fourth sparse one-message day", by: owner, at: day(2, hour: 10)),
            .init("DATE-07: Yesterday remains visible inline", at: day(1, hour: 10)),
            .init("DATE-08: Today begins a long section", by: owner, at: today),
            .init("DATE-09: The inline Today header can scroll away", at: today + 60),
            .init("DATE-10: Its pinned pill remains above the transcript", by: owner, at: today + 120),
            .init("DATE-11: More messages make this day span the viewport", at: today + 180),
            .init("DATE-12: Scrolling preserves the current day context", by: owner, at: today + 240),
            .init("DATE-13: Long sections keep their day context", at: today + 300),
            .init("DATE-14: Date headers remain visible in the transcript", by: owner, at: today + 360),
            .init("DATE-15: Long day keeps its date pinned", at: today + 420),
        ])
    }

    private static var referenceColors: Self {
        // Synthetic account IDs chosen for the nine production sender colors.
        let swatches: [(Int, String, String)] = [
            (110, "Amina Cole", "Red"),
            (101, "Bruno Diaz", "Orange"),
            (113, "Chloe Evans", "Green"),
            (103, "Darius Ford", "Teal"),
            (102, "Eleni Gray", "Blue"),
            (105, "Farah Hall", "Indigo"),
            (104, "Gideon Ito", "Purple"),
            (108, "Hana Jones", "Pink"),
            (107, "Imani King", "Brown")
        ]
        let start = day(0, hour: 9)
        let people = swatches.map { (String(format: "%064x", $0.0), $0.1) }
        let lines = swatches.enumerated().map { index, swatch in
            PreviewLine("COLOR-0\(index + 1): \(swatch.2) identity color", by: people[index].0,
                        at: start + TimeInterval(120 + index * 60))
        }
        return Self(29, "Group - Identity Colors", people: [(owner, "Marmota")] + people, lines)
    }

    private static var referenceAttachments: Self {
        let start = referenceNow - 15_000
        let voiceStart = referenceNow - 3_600
        func link(_ label: String, _ url: URL) -> [MarkdownBlockFfi] {
            [.paragraph(inlines: [.text(content: label + " "), .link(dest: url.absoluteString, title: nil,
                children: [.text(content: url.absoluteString)], classification: .web)])]
        }
        return Self(30, "Media - Files, Links & Voice", direct: true, [
            .init("FILE-01: Available PDF", .media(["Project Brief.pdf"]), at: start),
            .init("FILE-02: Available DOCX", .media(["Review Notes.docx"]), by: owner, at: start + 120),
            .init("FILE-03: Available XLSX", .media(["Budget.xlsx"]), at: start + 240),
            .init("FILE-04: Available ZIP", .media(["Assets.zip"]), by: owner, at: start + 360),
            .init("FILE-05: Available TXT", .media(["Read Me.txt"]), at: start + 480),
            .init("FILE-06: Unavailable file", .media(["Unavailable.pdf"]), by: owner, at: start + 600),
            .init("LINK-01: Link preview with image", .markdown(link("LINK-01: Link preview with image", designURL)), at: start + 780),
            .init("LINK-02: Link preview without image", .markdown(link("LINK-02: Link preview without image", whiteNoiseURL)), by: owner, at: start + 900),
            .init("LINK-03: Invalid destination", at: start + 1_020),
            .init("RICH-01: GIF", .media(["marmot-party.gif"]), by: owner, at: start + 1_200),
            .init("RICH-05: Valid contact", .media(["Avery Stone.vcf"]), at: start + 1_740),
            .init("VOICE-01 → next bubble: Incoming short voice message", by: owner, at: voiceStart),
            .init("", .media(["voice-7s.m4a"]), at: voiceStart + 60),
            .init("VOICE-02 → next bubble: Outgoing short voice message", at: voiceStart + 180),
            .init("", .media(["voice-18s.m4a"]), by: owner, at: voiceStart + 240),
            .init("VOICE-03 → next bubble: Voice duration over one minute", by: owner, at: voiceStart + 360),
            .init("", .media(["voice-82s.m4a"]), at: voiceStart + 420),
            .init("VOICE-04 → next bubble: Outgoing voice and text message", at: voiceStart + 540),
            .init("I’ll send the updated version this afternoon.", .media(["voice-12s.m4a"]), by: owner, at: voiceStart + 600),
        ])
    }

    private static var referenceEvents: Self {
        let start = referenceNow - 40_000
        return Self(31, "Group - Events Only", people: referencePeople, formerMembers: [elias], [
            .init("Maya Chen added Elias Moreno", .groupEvent("member_added", subject: elias), at: start),
            .init("Elias Moreno was made an admin", .groupEvent("admin_added", subject: elias), at: start + 60),
            .init("Elias Moreno left", .groupEvent("member_left", subject: elias), by: elias, at: start + 120),
        ])
    }

    private static var referenceLeftGroup: Self {
        let start = referenceNow - 3_600
        return Self(32, "Group - Left", people: [(owner, "Marmota"), (peer, "Maya Chen"), (elias, "Elias Moreno")], formerMembers: [owner], [
            .init("Maya Chen added you", .groupEvent("member_added", subject: owner), at: start + 60),
            .init("STATE-03: Group history remains readable after leaving.", at: start + 180),
            .init("You left the group.", .groupEvent("member_left", subject: owner), by: owner, at: start + 300),
        ])
    }

    private static var referenceMaya: Self {
        let inception = referenceNow - 45 * 86_400
        let mediaDay = referenceNow - 12 * 86_400
        let yesterday = referenceNow - 86_400
        let today = referenceNow - 3_600
        return Self(33, "Maya Chen", direct: true, people: [(owner, "Marmota"), (peer, "Maya Chen")], [
            .init("Hi—Maya here.", at: inception),
            .init("Hi Maya. Good to meet you.", by: owner, at: inception + 60),
            .init("I pulled the first draft together.\nCould you look at the opening and the final paragraph?", at: inception + 150),
            .init("Yes. I’ll read both before lunch.", .reply(2), by: owner, at: inception + 240),
            .init("This is the latest photo.", .media(["gallery-portrait.jpg"]), .reactionParticipants([("❤", [peer])]), by: owner, at: mediaDay),
            .init("The crop looks great.", .reply(4), at: mediaDay + 120),
            .init("Here’s the short clip.", .media(["trail.mp4"]), at: mediaDay + 570),
            .init("That movement makes the sequence much clearer.", .reply(6), by: owner, at: mediaDay + 660),
            .init("", .media(["voice.mp3"]), by: owner, at: yesterday + 450),
            .init("", .deleted, at: today),
            .init("", .deleted, by: owner, at: today + 120),
            .init("Replying to a message that’s no longer available.", .reply(9), by: owner, at: today + 240),
            .init("I’ll send the revised version now.", .failed, by: owner, at: today + 360),
            .init("Can you send the latest version when you have a moment?", .reactionParticipants([("👍", [owner]), ("😀", [owner, peer])]), at: today + 480),
        ])
    }

    private static var referenceWeekend: Self {
        let old = referenceNow - 400 * 86_400
        let earlyHistory = referenceNow - 120 * 86_400
        let yesterday = referenceNow - 86_400
        let today = referenceNow - 7_200
        return Self(34, "Weekend Walks", people: referencePeople + [(referenceLeo, "Leo Martins")], formerMembers: [referenceLeo], [
            .init("Thanks for setting this up.", at: old + 180),
            .init("That photo is from our first riverside route.", at: earlyHistory + 360),
            .init("I still like that path best.", at: earlyHistory + 420),
            .init("@Marmota, does the riverside path work?", .namedMentions([("Marmota", owner)]), at: yesterday),
            .init("Yes, and the forecast looks clear.", .reply(3), by: owner, at: yesterday + 120),
            .init("Then let’s keep the changing details here instead of in the description.", .reply(4), by: nora, at: yesterday + 240),
            .init("This clip shows the narrow section.", .media(["trail.mp4"]), at: yesterday + 360),
            .init("And here’s the bridge beside it.", .reply(6), .media(["portrait-study.jpg", "trail.mp4"]), by: owner, at: yesterday + 480),
            .init("", .media(["marmot-party.gif"]), .reactionParticipants([("🤣", [owner, peer])]), by: referenceLeo, at: today),
            .init("Not the steep shortcut—the entrance with the sunlit trees.", .media(["portrait-study.jpg"]), .reactionParticipants([("👎", [owner, nora])]), at: today + 240),
            .init("", .media(["route.pdf"]), by: nora, at: today + 480),
            .init("", .media(["voice.mp3"]), by: owner, at: today + 600),
            .init("I’m stepping out, but I hope the walk goes well.", by: referenceLeo, at: today + 720),
            .init("Leo Martins left", .groupEvent("member_left", subject: referenceLeo), by: referenceLeo, at: today + 840),
            .init("Saturday morning works for me.", by: nora, at: today + 1_200),
        ])
    }
}
#endif
