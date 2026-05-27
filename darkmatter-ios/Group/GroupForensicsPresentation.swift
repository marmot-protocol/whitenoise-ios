import Foundation
import MarmotKit

enum GroupForensicsPresentation {
    static func modeLabel(_ mode: ForensicsDumpModeFfi) -> String {
        switch mode {
        case .`public`:
            "Public"
        case .sensitive:
            "Private"
        }
    }

    static func fileName(
        groupTitle: String,
        groupIdHex: String,
        mode: ForensicsDumpModeFfi,
        generatedAt: Date
    ) -> String {
        [
            slug(groupTitle),
            String(groupIdHex.prefix(8)),
            modeLabel(mode).lowercased(),
            "forensics",
            timestamp(generatedAt)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "-") + ".json"
    }

    private static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var result = ""
        var previousWasSeparator = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
