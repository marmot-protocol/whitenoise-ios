import Foundation

nonisolated struct MessageLinkSegment: Equatable {
    let text: AttributedString
    let target: MessageLinkTarget?

    static func segments(of text: AttributedString) -> [MessageLinkSegment] {
        text.runs[\.link].map { link, range in
            MessageLinkSegment(
                text: AttributedString(text[range]),
                target: link.flatMap(MessageLinkTarget.init(url:))
            )
        }
    }
}
