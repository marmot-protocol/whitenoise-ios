#if DEBUG
import Foundation
import MarmotKit

/// Fixture mutations publish complete replacements to the open screen and inbox.
@MainActor
struct ChatPreviewActions {
    let windows: ChatPreviewWindows
    let id: String

    func replay(_ scenario: ChatPreviewWindows.OpenScenario?, using model: ConversationViewModel) async {
        windows.openScenarios[id] = scenario
        await model.start()
    }

    func send(_ text: String, replyTo: String? = nil, incoming: Bool = false) {
        windows.change(id) { chat in
            let author = incoming ? ChatPreviewThread.peer : ChatPreviewThread.owner
            let line: PreviewLine
            if let replyTo, let index = chat.messages.firstIndex(where: { $0.timeline.messageIdHex == replyTo }) {
                line = PreviewLine(text, .reply(index), by: author)
            } else { line = PreviewLine(text, by: author) }
            chat.append(line, at: UInt64(Date().timeIntervalSince1970))
        }
    }

    func react(_ emoji: String, to messageID: String) {
        windows.change(id) { chat in
            chat.update(messageID) { message in
                var items = message.references.reactions.items
                let owner = ChatPreviewThread.owner
                if items.contains(where: { $0.emoji == emoji && $0.viewerReacted }) {
                    // The live unreact operation clears this viewer's reactions on the target.
                    for index in items.indices where items[index].viewerReacted {
                        items[index].viewerReacted = false
                        items[index].reactors.removeAll { $0 == owner }
                        items[index].count -= 1
                    }
                    items.removeAll { $0.count == 0 }
                } else if let index = items.firstIndex(where: { $0.emoji == emoji }) {
                    items[index].viewerReacted = true
                    items[index].reactors.append(owner)
                    items[index].count += 1
                } else {
                    items.append(.init(emoji: emoji, count: 1, reactors: [owner], viewerReacted: true, reactionMessageIdHex: nil))
                }
                message.references.reactions = .init(totalCount: items.reduce(0) { $0 + $1.count },
                    totalKinds: UInt64(items.count), items: items, omittedKinds: 0)
                message.timeline.reactions.byEmoji = items.map { .init(emoji: $0.emoji, count: UInt32($0.count), senders: $0.reactors) }
            }
        }
    }

    func vote(_ optionID: String, on messageID: String) {
        windows.change(id) { chat in
            chat.update(messageID) { message in
                guard let poll = message.timeline.poll, PollPresentation.isOpen(poll, now: .now),
                      let choices = PollPresentation.toggledSelection(current: poll.localSelection, option: optionID,
                          pollType: poll.pollType, optionOrder: poll.options.map(\.id)) else { return }
                message.timeline.poll = PollPresentation.applyingLocalSelection(choices, to: poll)
            }
        }
    }

    func retry(_ messageID: String) {
        windows.change(id) { chat in
            chat.update(messageID) { message in
                message.timeline.invalidationStatus = nil
                message.timeline.sourceMessageIdHex = messageID
            }
        }
    }

    func hide(_ messageID: String) {
        windows.change(id) { $0.hide(messageID) }
    }

    func delete(_ ids: Set<String>) {
        windows.change(id) { chat in
            for id in ids {
                chat.redactQuotes(of: id)
                chat.update(id) { message in
                    message.timeline.deleted = true
                    message.timeline.deletionSource = .author
                    message.timeline.plaintext = ""
                    message.timeline.contentTokens = .emptyDocument
                    message.timeline.media = []
                    message.timeline.poll = nil
                    message.timeline.sticker = nil
                    message.timeline.invalidationStatus = nil
                }
            }
        }
    }
}
#endif
