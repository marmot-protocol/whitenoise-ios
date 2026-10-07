import Foundation

nonisolated struct MarkdownTimestamp: Hashable, Sendable {
    enum Style: String, CaseIterable, Sendable {
        case shortTime = "t", longTime = "T", shortDate = "d", longDate = "D"
        case shortDateTime = "f", longDateTime = "F", compactDateTime = "s"
        case compactDateTimeSeconds = "S", relative = "R"
    }

    let unixSeconds: Int64
    let style: Style

    var token: String { "<t:\(unixSeconds):\(style.rawValue)>" }

    static func project(_ source: AttributedString, label: (MarkdownTimestamp) -> String) -> String {
        source.runs.map { run in
            run[MarkdownTimestampAttribute.self].map { "◷ " + label($0) }
                ?? String(source[run.range].characters)
        }.joined()
    }

    func absoluteLabel(locale: Locale = .autoupdatingCurrent,
                       timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let date = Date(timeIntervalSince1970: Double(unixSeconds))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        let template: String
        switch style {
        case .shortTime: template = "jm"
        case .longTime: template = "jms"
        case .shortDate: template = "yMd"
        case .longDate: template = "yMMMMd"
        case .shortDateTime: template = "yMMMMdjm"
        case .longDateTime: template = "EEEEyMMMMdjm"
        case .compactDateTime: template = "yMdjm"
        case .compactDateTimeSeconds: template = "yMdjms"
        case .relative: preconditionFailure("relative style requires the native relative formatter")
        }
        formatter.setLocalizedDateFormatFromTemplate(template)
        let label = formatter.string(from: date)
        // Foundation cannot represent every i64 epoch as a calendar date. Keep the exact instant.
        return label.isEmpty ? token : label
    }

    func relativeComponents(now: Date) -> DateComponents {
        let epoch = now.timeIntervalSince1970
        let current = epoch <= Double(Int64.min) ? Int64.min
            : epoch >= Double(Int64.max) ? Int64.max : Int64(epoch.rounded(.down))
        let at = UInt64(bitPattern: unixSeconds) ^ (1 << 63)
        let reference = UInt64(bitPattern: current) ^ (1 << 63)
        let future = at > reference
        let distance = future ? at - reference : reference - at
        let units: [(Calendar.Component, UInt64)] = [
            (.year, 31_536_000), (.month, 2_592_000), (.day, 86_400),
            (.hour, 3_600), (.minute, 60), (.second, 1)
        ]
        let unit = units.first { distance >= $0.1 } ?? units[units.count - 1]
        let count = Int(distance / unit.1)
        var components = DateComponents()
        components.setValue(future ? count : -count, for: unit.0)
        return components
    }
}

nonisolated enum MarkdownTimestampAttribute: AttributedStringKey {
    typealias Value = MarkdownTimestamp
    static let name = "dev.ipf.whitenoise.markdown.timestamp"
}

nonisolated enum MarkdownTimestampOccurrenceAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "dev.ipf.whitenoise.markdown.timestamp.occurrence"
}
