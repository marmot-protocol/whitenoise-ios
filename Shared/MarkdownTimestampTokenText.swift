import Foundation
import MarmotKit

/// Replaces `<t:UNIX_SECONDS>` / `<t:UNIX_SECONDS:STYLE>` source tokens in raw
/// message text with a formatted time. Notification previews arrive from MDK
/// as raw plaintext rather than parsed tokens, so without this they would show
/// the literal syntax. Mirrors MDK's grammar: ASCII digits with an optional
/// leading `-`, a signed 64-bit range, and one of the nine style letters.
/// Backslash-escaped tokens and tokens inside backtick code spans stay literal,
/// as they do in MDK's parser.
nonisolated enum MarkdownTimestampTokenText {
    static let maxReplacements = 32

    static func replacingTokens(
        in raw: String,
        maxReplacements: Int = maxReplacements,
        format: (Int64, MarkdownTimestampStyleFfi) -> String = { seconds, style in
            MarkdownTimestampFormatter.staticText(unixSeconds: seconds, style: style)
        }
    ) -> String {
        guard raw.contains("<t:") else { return raw }
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        var replacements = 0
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                out.append(scalar)
                out.append(scalars[index + 1])
                index += 2
                continue
            }
            if scalar == "`" {
                let end = codeSpanEnd(scalars, from: index)
                out.append(contentsOf: scalars[index..<end])
                index = end
                continue
            }
            if scalar == "<", replacements < maxReplacements,
               let (seconds, style, end) = token(scalars, at: index) {
                out.append(contentsOf: format(seconds, style).unicodeScalars)
                replacements += 1
                index = end
                continue
            }
            out.append(scalar)
            index += 1
        }
        return String(out)
    }

    /// End of the backtick run at `start`, extended through its matching
    /// closing run when one exists (a code span); otherwise just the run.
    private static func codeSpanEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var openEnd = start
        while openEnd < scalars.count, scalars[openEnd] == "`" { openEnd += 1 }
        let width = openEnd - start
        var cursor = openEnd
        while cursor < scalars.count {
            guard scalars[cursor] == "`" else {
                cursor += 1
                continue
            }
            var runEnd = cursor
            while runEnd < scalars.count, scalars[runEnd] == "`" { runEnd += 1 }
            if runEnd - cursor == width { return runEnd }
            cursor = runEnd
        }
        return openEnd
    }

    private static func token(
        _ scalars: [Unicode.Scalar],
        at start: Int
    ) -> (Int64, MarkdownTimestampStyleFfi, Int)? {
        guard start + 2 < scalars.count,
              scalars[start + 1] == "t",
              scalars[start + 2] == ":" else { return nil }
        var cursor = start + 3
        var number = ""
        if cursor < scalars.count, scalars[cursor] == "-" {
            number.unicodeScalars.append("-")
            cursor += 1
        }
        let digitsStart = cursor
        while cursor < scalars.count, scalars[cursor].isASCII, ("0"..."9").contains(scalars[cursor]) {
            number.unicodeScalars.append(scalars[cursor])
            cursor += 1
        }
        guard cursor > digitsStart, let seconds = Int64(number) else { return nil }
        var style = MarkdownTimestampStyleFfi.shortDateTime
        if cursor < scalars.count, scalars[cursor] == ":" {
            guard cursor + 1 < scalars.count,
                  let parsed = MarkdownTimestampFormatter.style(token: Character(scalars[cursor + 1]))
            else { return nil }
            style = parsed
            cursor += 2
        }
        guard cursor < scalars.count, scalars[cursor] == ">" else { return nil }
        return (seconds, style, cursor + 1)
    }
}
