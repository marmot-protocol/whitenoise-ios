#if DEBUG
import Foundation
import MarmotKit

extension ChatPreviewThread {
    static let guideURL = URL(string: "https://fieldnotes.example/trail")!
    static let designURL = URL(string: "https://developer.apple.com/design/human-interface-guidelines")!
    static let whiteNoiseURL = URL(string: "https://whitenoise.chat")!
    static func linkMetadata(for url: URL) -> LinkPreviewMetadata? {
        switch url {
        case guideURL: return .init(title: "Field notes from the ridge", imageURL: nil)
        case whiteNoiseURL: return .init(title: "White Noise", imageURL: nil)
        case designURL:
            let image = Bundle.main.url(forResource: "ChatPreviewMedia", withExtension: "bundle")?
                .appendingPathComponent("open-circuit.jpg")
            return .init(title: "Human Interface Guidelines", imageURL: image)
        default: return nil
        }
    }

    static let examples: [Self] = {
        let long = String(repeating: "We took the path through the orchard. The steps after the bridge are steep, but the view from the top is worth the climb.\n\n", count: 15)
        let weekendPoll = PreviewLine("When should we meet?", .poll(closed: false))
        let photos = PreviewLine("A few favorites from the contact sheet.", .media(["portrait-study.jpg", "portrait.jpg", "studio.jpg"]))
        let location = PreviewLine("https://maps.apple.com/?ll=44.8167,20.4667")
        let link = guideURL.absoluteString
        let guide = PreviewLine(link, .markdown([.paragraph(inlines: [
            .link(dest: link, title: nil, children: [.text(content: link)], classification: .web)
        ])]))
        let notes = PreviewLine("Saturday notes", .markdown([
            .heading(level: 2, inlines: [.text(content: "Saturday notes")]),
            .paragraph(inlines: [.strong(children: [.text(content: "Bring water.")]), .text(content: " Meet by the "),
                                 .emph(children: [.text(content: "old")]), .text(content: " bridge.")]),
            .blockQuote(blocks: [.paragraph(inlines: [.text(content: "The lower gate opens at nine.")])], blankLinesBefore: Data([0])),
            .paragraph(inlines: [.text(content: "Use gate "), .code(content: "B12"), .text(content: ".")]),
            .codeBlock(kind: .fenced, info: "swift", content: "let gate = \"B12\"\nlet departure = \"09:30\"")
        ]))
        let unreadStart = 275
        let history = (1...360).map { index in
            if index == 360 { return PreviewLine("This is where the trail log started.", .reply(0), by: peer) }
            let observations = ["Clear skies over the ridge.", "Bridge crossing open.", "Still some snow on the north side."]
            return PreviewLine("Trail log \(index) · \(observations[index % observations.count])",
                               by: index > unreadStart ? (index.isMultiple(of: 2) ? peer : third) : members[index % members.count].0)
        }
        return [
            Self(1, "01 · Bubble Rhythm", [
                .init("Morning!"), .init("I found the entrance."), .init("Take the stairs beside the bookshop and turn left at the blue door."),
                .init("Coming up.", by: owner), .init("☕️", by: owner), .init("Saved you a seat.", by: third)
            ]),
            Self(2, "02 · Text & Markdown", [notes, .init("مرحبا · こんにちは · Hello 👋"), .init("One more detail:\n\nBring a light jacket.", by: owner)]),
            Self(3, "03 · Delivery & Metadata", [.init("This one made it.", by: owner), .init("Waiting for a connection.", .pending, by: owner), .init("The updated time is 10:30.", .edited),
                .init("Please review the group notice.", .reported), .init("My connection dropped.", .failed, by: owner), .init("", .deleted)]),
            Self(4, "04 · Emoji & Stickers", [.init("🥾"), .init("👩🏽‍🚀 👨‍👩‍👧‍👦"), .init(":marmot:"), .init("Trail crew :wn: 🎒"),
                .init("", .sticker), .init("", .sticker, by: owner), .init(":marmot_wave:", .reply(0), by: third)]),
            Self(5, "05 · People & Mentions", [.init("Are you joining us?", .mention), .init("Yes!", by: owner), .init("Me too.", by: third)]),
            Self(6, "06 · Replies & Long Messages", [.init("Which route did you take?"), .init(long, .reply(0, inThread: true), by: owner), .init("I'll save this.", .reply(1, inThread: true))]),
            Self(7, "07 · Photos & Albums", [.init("At the studio", .media(["tall-portrait.jpg"])),
                .init("", .media(["studio-panorama.jpg"])), photos,
                .init("Same subject from another angle", .reply(0), .media(["tall-portrait.jpg"]), by: owner),
                .init("Proof and notes", .media(["tall-portrait.jpg", "route.pdf"])),
                .init("A little loop for the group", .media(["marmot-party.gif"])),
                .init("Rest of the roll", .media(["portrait.jpg", "studio.jpg", "tall-portrait.jpg", "trail.mp4", "portrait-study.jpg", "studio-panorama.jpg"])),
                .init("", .rejectedMedia)]),
            Self(8, "08 · Voice, Video & Files", [.init("", .media(["morning.wav"])), .init("From the trail", .media(["trail.mp4"])),
                                                   .init("Trail plan for Saturday", .media(["route.pdf"]))]),
            Self(9, "09 · Links & Locations", [guide, .init("Meet here?"), location]),
            Self(10, "10 · Polls", [weekendPoll, .init("Which sessions could you attend?", .poll(closed: false, type: .multipleChoice), .reply(0), by: owner),
                .init("Last week's vote", .poll(closed: true)), .init("", .malformedPoll)]),
            Self(11, "11 · Reactions", [.init("First print!", .reactions(["🌷"])), .init("We made it!", .reactions(["🎉","🥾",":marmot:","🧡","🙌","🌱","✨"]))]),
            Self(12, "12 · Menus & Selection", [.init("Pick a postcard.", by: owner), .init("I like the green one.", .reply(0)),
                                                  .init(long), .init("", .deleted), .init("One more to select.", by: third)]),
            Self(13, "13 · Dates, Unread & Scrolling", firstUnread: unreadStart, openingDaysAgo: [250, 120, 60, 30, 18, 12, 9], history),
            Self(14, "14 · Empty, Loading & Recovery", []),
            Self(15, "15 · System & Agent Messages", people: members + [(trailBot, "Trail Bot")], [
                .init("Leo joined the group", .groupEvent("member_added")), .init("Leo became an admin", .groupEvent("admin_added"), by: owner),
                .init("New messages disappear after one day", .groupEvent("disappearing_timer_changed")),
                .init("Trail Bot, can we get from the north gate to the lake without using the steps?"),
                .init("Checking the trail map", .activity(replyingTo: 3), by: trailBot),
                .init("Good call. I’ll have the stroller with me.", by: third),
                .init("Take the lakeside path just past the kiosk. It skips the steps and adds about ten minutes.", .reply(3), by: trailBot),
                .init("Perfect. I can meet you at the kiosk.", by: owner),
                .init("Trail Bot, which bus stop is closest to that gate?", by: third),
                .init("Looking up the bus stop", .activity(replyingTo: 8), by: trailBot),
                .init("I’ll be coming by bus too."),
                .init("Pine Street. Get off by the bakery and cross at the lights. The north gate is on your left.", .reply(8), by: trailBot),
                .init("Pine Street it is. See you at ten!", by: third),
                .init("@Trail Bot, how long is the walk from Pine Street to the kiosk?", .namedMentions([("Trail Bot", trailBot)]), by: owner),
                .init("Tracing the walk from Pine Street", .activity(replyingTo: 13), by: trailBot),
                .init("My bus gets in at 9:45. I can wait by the bakery."),
                .init("About eight minutes through the north gate. Allow ten if you’re bringing the stroller.", .reply(13), by: trailBot),
                .init("@Trail Bot, can you put the meeting time and directions in one message for the group?", .namedMentions([("Trail Bot", trailBot)]), by: owner),
                .init("Putting the directions together", .activity(replyingTo: 17), by: trailBot),
                .init("Could you include the step-free path too?", by: third),
                .init("Yes please. I’ll send it to Sam.", by: owner),
                .init("Meet at the north gate kiosk at 10. From the Pine Street stop, cross at the bakery lights and walk through the gate. From the kiosk, take the lakeside path to avoid the steps.", .reply(17), by: trailBot),
                .init("@Trail Bot, is there a water fountain near the kiosk?", .namedMentions([("Trail Bot", trailBot)]), by: owner),
                .init("Checking the park facilities", .activity(replyingTo: 22), by: trailBot)
            ]),
            Self(16, "16 · Disappearing Messages", disappearingMessageSecs: 86_400, [.init("Gate code for today", .expires), .init("Got it.", .expires, by: owner), .init("The meeting point stays here.")]),
            Self(17, "Weekend Trip", [.init("Anyone up for a walk?"), weekendPoll, .init("Sunday works for me.", .reply(1), by: third),
                                       location, photos, .init("See you there!", .reactions(["🥾","☀️"]), by: owner)]),
            Self(18, "Launch Prep", [.init("Leo joined the group", .groupEvent("member_added")), notes, .init("Can you check the launch-day hike plan?", .mention),
                                      .init("Here’s the route for the team walk.", .media(["route.pdf"]), by: owner), .init("Looks good to me.", .reply(3), .reactions(["👍"]))]),
            Self(19, "Family Chat", [.init("Look who sat for a portrait today", .media(["portrait-study.jpg"])), .init("😍😍😍", by: third),
                                      .init("Grandma would love that.", .reply(0), by: owner), .init("", .media(["marmot-party.gif"]), by: third), .init("Lunch at one?", .edited), .init("Yes!", .reactions(["❤️"]))]),
            Self(20, "Maya · Everyday Conversation", direct: true, [.init("Is the bakery on your way home?"), .init("It is. The usual?", by: owner),
                 .init("Two rolls please.", .reply(1)), .init("Already in the bag 🥖", by: owner), .init("You read my mind.", .reactions(["❤️"]))])
        ] + referenceExamples
    }()
}
#endif
