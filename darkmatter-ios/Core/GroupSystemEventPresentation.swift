import Foundation
import MarmotKit

/// Display projection for durable group system rows (kind 1210).
///
/// UniFFI only parses markdown for kind 9, so these rows arrive with empty
/// `content_tokens` and JSON in `plaintext`. Clients SHOULD render from
/// `system_type` plus structured `data` so rows can be localized and
/// re-resolved as display names change.
enum GroupSystemEventPresentation {

    typealias DisplayNameResolver = (String) -> String

    static func isDisplayable(_ record: AppMessageRecordFfi) -> Bool {
        guard case .groupSystem = MessageSemantics.classify(record) else { return false }
        return parsePayload(record.plaintext) != nil
    }

    static func displayText(
        for record: AppMessageRecordFfi,
        displayName: DisplayNameResolver
    ) -> String? {
        guard case .groupSystem = MessageSemantics.classify(record) else { return nil }
        return displayText(
            from: record.plaintext,
            sender: record.sender,
            displayName: displayName
        )
    }

    static func displayText(
        from plaintext: String,
        sender: String = "",
        displayName: DisplayNameResolver = { IdentityFormatter.short($0) }
    ) -> String? {
        guard let payload = parsePayload(plaintext) else { return nil }
        return payload.resolvedText(sender: sender, displayName: displayName)
    }

    private static func parsePayload(_ plaintext: String) -> Payload? {
        guard let data = plaintext.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var actor: String?
        var subject: String?
        var name: String?
        var oldRetentionSeconds: UInt64?
        var newRetentionSeconds: UInt64?
        if let payloadData = root["data"] as? [String: Any] {
            actor = payloadData["actor"] as? String
            subject = payloadData["subject"] as? String
            name = payloadData["name"] as? String
            oldRetentionSeconds = uint64Value(payloadData["old_retention_seconds"])
            newRetentionSeconds = uint64Value(payloadData["new_retention_seconds"])
        }

        return Payload(
            text: root["text"] as? String,
            systemType: root["system_type"] as? String,
            actor: actor,
            subject: subject,
            name: name,
            oldRetentionSeconds: oldRetentionSeconds,
            newRetentionSeconds: newRetentionSeconds
        )
    }

    static func retentionSettingLabel(seconds: UInt64) -> String {
        seconds == 0 ? L10n.string("Off") : retentionDurationText(seconds: seconds)
    }

    private static func retentionDurationText(seconds: UInt64) -> String {
        let locale = AppLanguage.currentLocale
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        let clamped = min(seconds, UInt64(Int.max))
        return formatter.string(from: TimeInterval(clamped))
            ?? fallbackRetentionDuration(seconds: clamped, locale: locale)
    }

    private static func fallbackRetentionDuration(seconds: UInt64, locale: Locale) -> String {
        let measurementFormatter = MeasurementFormatter()
        measurementFormatter.locale = locale
        measurementFormatter.unitStyle = .long

        let numberFormatter = NumberFormatter()
        numberFormatter.locale = locale
        numberFormatter.numberStyle = .decimal
        measurementFormatter.numberFormatter = numberFormatter

        if seconds >= 3_600, seconds.isMultiple(of: 3_600) {
            return measurementFormatter.string(
                from: Measurement(value: Double(seconds / 3_600), unit: UnitDuration.hours)
            )
        }
        if seconds >= 60, seconds.isMultiple(of: 60) {
            return measurementFormatter.string(
                from: Measurement(value: Double(seconds / 60), unit: UnitDuration.minutes)
            )
        }
        return measurementFormatter.string(
            from: Measurement(value: Double(seconds), unit: UnitDuration.seconds)
        )
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            return value
        case let value as Int where value >= 0:
            return UInt64(value)
        case let value as NSNumber:
            let doubleValue = value.doubleValue
            guard doubleValue.isFinite,
                  doubleValue >= 0,
                  doubleValue <= Double(Int.max),
                  doubleValue.rounded(.towardZero) == doubleValue
            else { return nil }
            return UInt64(doubleValue)
        default:
            return nil
        }
    }

    private struct Payload {
        var text: String?
        var systemType: String?
        var actor: String?
        var subject: String?
        var name: String?
        var oldRetentionSeconds: UInt64?
        var newRetentionSeconds: UInt64?

        func resolvedText(sender: String, displayName: DisplayNameResolver) -> String? {
            let actorHex = normalizedHex(actor) ?? normalizedHex(sender.isEmpty ? nil : sender)
            let subjectHex = normalizedHex(subject)
            let actorName = actorHex.map(displayName)
            let subjectName = subjectHex.map(displayName)
            let groupName = ProfileSanitizer.groupName(name)

            if let systemType = trimmed(systemType) {
                switch systemType {
                case "member_added":
                    if let actorName, let subjectName {
                        return L10n.formatted("%@ added %@", actorName, subjectName)
                    }
                    if let subjectName {
                        return L10n.formatted("%@ was added", subjectName)
                    }
                case "member_removed":
                    if let actorName, let subjectName {
                        return L10n.formatted("%@ removed %@", actorName, subjectName)
                    }
                    if let subjectName {
                        return L10n.formatted("%@ was removed", subjectName)
                    }
                case "member_left":
                    if let subjectName {
                        return L10n.formatted("%@ left", subjectName)
                    }
                case "admin_added":
                    if let actorName, let subjectName {
                        return L10n.formatted("%@ made %@ an admin", actorName, subjectName)
                    }
                    if let subjectName {
                        return L10n.formatted("%@ was made an admin", subjectName)
                    }
                case "admin_removed":
                    if let actorName, let subjectName {
                        return L10n.formatted("%@ removed %@ as admin", actorName, subjectName)
                    }
                    if let subjectName {
                        return L10n.formatted("%@ is no longer an admin", subjectName)
                    }
                case "group_renamed":
                    if let groupName {
                        return L10n.formatted("Group renamed to %@", groupName)
                    }
                    return L10n.string("Group renamed")
                case "group_avatar_changed":
                    return L10n.string("Group avatar changed")
                case "disappearing_timer_changed":
                    if let newRetentionSeconds {
                        return disappearingTimerText(
                            actorName: actorName,
                            oldRetentionSeconds: oldRetentionSeconds,
                            newRetentionSeconds: newRetentionSeconds
                        )
                    }
                default:
                    break
                }
            }

            if let text = sanitizedFallback(text) { return text }
            if let systemType = sanitizedFallback(systemType) {
                let phrase = systemType.replacingOccurrences(of: "_", with: " ")
                guard let sanitized = sanitizedFallback(phrase) else { return nil }
                return sanitized.prefix(1).uppercased() + sanitized.dropFirst()
            }
            return nil
        }

        private func trimmed(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func sanitizedFallback(_ value: String?) -> String? {
            guard let value = trimmed(value) else { return nil }
            return ProfileSanitizer.singleLine(value, maxLength: ProfileSanitizer.maxGroupNameLength)
        }

        private func normalizedHex(_ value: String?) -> String? {
            guard let value = trimmed(value) else { return nil }
            return value.lowercased()
        }

        private func disappearingTimerText(
            actorName: String?,
            oldRetentionSeconds: UInt64?,
            newRetentionSeconds: UInt64
        ) -> String {
            if newRetentionSeconds == 0 {
                if let actorName {
                    return L10n.formatted("%@ turned off disappearing messages", actorName)
                }
                return L10n.string("Disappearing messages turned off")
            }

            let newText = GroupSystemEventPresentation.retentionDurationText(seconds: newRetentionSeconds)
            if let oldRetentionSeconds,
               oldRetentionSeconds > 0,
               oldRetentionSeconds != newRetentionSeconds {
                let oldText = GroupSystemEventPresentation.retentionDurationText(seconds: oldRetentionSeconds)
                if let actorName {
                    return L10n.formatted(
                        "%@ changed disappearing messages from %@ to %@",
                        actorName,
                        oldText,
                        newText
                    )
                }
                return L10n.formatted(
                    "Disappearing messages changed from %@ to %@",
                    oldText,
                    newText
                )
            }

            if let actorName {
                return L10n.formatted("%@ set disappearing messages to %@", actorName, newText)
            }
            return L10n.formatted("Disappearing messages set to %@", newText)
        }
    }
}
