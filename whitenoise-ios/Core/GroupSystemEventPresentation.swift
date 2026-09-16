import Foundation
import MarmotKit

/// Display projection for durable group system rows (kind 1210).
///
/// UniFFI only parses markdown for kind 9, so these rows arrive with empty
/// `content_tokens` and JSON in `plaintext`. Clients SHOULD render from
/// `system_type` plus structured `data` so rows can be localized and
/// re-resolved as display names change.
nonisolated enum GroupSystemEventPresentation {

    typealias DisplayNameResolver = (String) -> String

    fileprivate enum Participant {
        case current
        case other(String)
    }

    static func isDisplayable(_ record: AppMessageRecordFfi) -> Bool {
        isDisplayable(record, groupSystem: nil)
    }

    static func isDisplayable(
        _ record: AppMessageRecordFfi,
        groupSystem: GroupSystemEventFfi?
    ) -> Bool {
        guard case .groupSystem = MessageSemantics.classify(record) else { return false }
        return groupSystem != nil || parsePayload(record.plaintext) != nil
    }

    static func displayText(
        for record: AppMessageRecordFfi,
        groupSystem: GroupSystemEventFfi? = nil,
        currentAccountIdHex: String? = nil,
        displayName: DisplayNameResolver
    ) -> String? {
        guard case .groupSystem = MessageSemantics.classify(record) else { return nil }
        let payload = groupSystem.map(Payload.init) ?? parsePayload(record.plaintext)
        return payload?.resolvedText(
            sender: record.sender,
            currentAccountIdHex: currentAccountIdHex,
            displayName: displayName
        )
    }

    static func displayText(
        from plaintext: String,
        sender: String = "",
        currentAccountIdHex: String? = nil,
        displayName: DisplayNameResolver = { IdentityPresentation.text(accountIdHex: $0) }
    ) -> String? {
        guard let payload = parsePayload(plaintext) else { return nil }
        return payload.resolvedText(
            sender: sender,
            currentAccountIdHex: currentAccountIdHex,
            displayName: displayName
        )
    }

    private static func parsePayload(_ plaintext: String) -> Payload? {
        // Same ceiling as the media-preview parser: a hostile multi-megabyte
        // payload must not force a full synchronous parse on the MainActor.
        guard plaintext.utf8.count <= MessagePreview.timelineMediaPreviewMaxJsonBytes,
              let data = plaintext.data(using: .utf8),
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

    static func retentionDurationText(
        seconds: UInt64,
        locale: Locale = AppLanguage.currentLocale,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let formatter = DateComponentsFormatter()
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        formatter.calendar = localizedCalendar
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        let clamped = min(seconds, UInt64(Int.max))
        return formatter.string(from: elapsedDurationComponents(seconds: clamped))
            ?? fallbackRetentionDuration(seconds: clamped, locale: locale)
    }

    /// Retention is an exact elapsed duration, not a wall-clock interval.
    /// Decompose it directly so crossing a daylight-saving boundary cannot add
    /// or remove an hour from the label.
    private static func elapsedDurationComponents(seconds: UInt64) -> DateComponents {
        let days = seconds / 86_400
        let afterDays = seconds % 86_400
        let hours = afterDays / 3_600
        let afterHours = afterDays % 3_600
        let minutes = afterHours / 60

        return DateComponents(
            day: Int(days),
            hour: Int(hours),
            minute: Int(minutes),
            second: Int(afterHours % 60)
        )
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

        init(_ event: GroupSystemEventFfi) {
            text = event.text
            systemType = event.systemType
            actor = event.actorAccountIdHex
            subject = event.subjectAccountIdHex
            name = event.name
            oldRetentionSeconds = event.oldRetentionSeconds
            newRetentionSeconds = event.newRetentionSeconds
        }

        init(
            text: String?,
            systemType: String?,
            actor: String?,
            subject: String?,
            name: String?,
            oldRetentionSeconds: UInt64?,
            newRetentionSeconds: UInt64?
        ) {
            self.text = text
            self.systemType = systemType
            self.actor = actor
            self.subject = subject
            self.name = name
            self.oldRetentionSeconds = oldRetentionSeconds
            self.newRetentionSeconds = newRetentionSeconds
        }

        func resolvedText(
            sender: String,
            currentAccountIdHex: String?,
            displayName: DisplayNameResolver
        ) -> String? {
            let current = normalizedHex(currentAccountIdHex)
            let resolvedActor = participant(
                normalizedHex(actor) ?? normalizedHex(sender.isEmpty ? nil : sender),
                current: current,
                displayName: displayName
            )
            let resolvedSubject = participant(
                normalizedHex(subject),
                current: current,
                displayName: displayName
            )
            let groupName = ContentSanitizer.groupName(name)

            if let systemType = trimmed(systemType) {
                switch systemType {
                case "member_added":
                    if let text = memberAddedText(actor: resolvedActor, subject: resolvedSubject) {
                        return text
                    }
                case "member_removed":
                    if let text = memberRemovedText(actor: resolvedActor, subject: resolvedSubject) {
                        return text
                    }
                case "member_left":
                    if let text = memberLeftText(resolvedActor ?? resolvedSubject) {
                        return text
                    }
                case "admin_added":
                    if let text = adminAddedText(actor: resolvedActor, subject: resolvedSubject) {
                        return text
                    }
                case "admin_removed":
                    if let text = adminRemovedText(actor: resolvedActor, subject: resolvedSubject) {
                        return text
                    }
                case "group_renamed":
                    return groupRenamedText(actor: resolvedActor, groupName: groupName)
                case "group_avatar_changed":
                    return groupAvatarChangedText(actor: resolvedActor)
                case "disappearing_timer_changed":
                    if let newRetentionSeconds {
                        return disappearingTimerText(
                            actor: resolvedActor,
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

        private func participant(
            _ accountIdHex: String?,
            current: String?,
            displayName: DisplayNameResolver
        ) -> Participant? {
            guard let accountIdHex else { return nil }
            return accountIdHex == current ? .current : .other(displayName(accountIdHex))
        }

        private func memberAddedText(actor: Participant?, subject: Participant?) -> String? {
            switch (actor, subject) {
            case (.current?, .other(let subject)?):
                L10n.formatted("You added %@", subject)
            case (.other(let actor)?, .current?):
                L10n.formatted("%@ added you", actor)
            case (.other(let actor)?, .other(let subject)?):
                L10n.formatted("%@ added %@", actor, subject)
            case (_, .current?):
                L10n.string("You were added")
            case (_, .other(let subject)?):
                L10n.formatted("%@ was added", subject)
            case (_, nil):
                nil
            }
        }

        private func memberRemovedText(actor: Participant?, subject: Participant?) -> String? {
            switch (actor, subject) {
            case (.current?, .other(let subject)?):
                L10n.formatted("You removed %@", subject)
            case (.other(let actor)?, .current?):
                L10n.formatted("%@ removed you", actor)
            case (.other(let actor)?, .other(let subject)?):
                L10n.formatted("%@ removed %@", actor, subject)
            case (_, .current?):
                L10n.string("You were removed")
            case (_, .other(let subject)?):
                L10n.formatted("%@ was removed", subject)
            case (_, nil):
                nil
            }
        }

        private func memberLeftText(_ leaving: Participant?) -> String? {
            switch leaving {
            case .current?:
                L10n.string("You left")
            case .other(let name)?:
                L10n.formatted("%@ left", name)
            case nil:
                nil
            }
        }

        private func adminAddedText(actor: Participant?, subject: Participant?) -> String? {
            switch (actor, subject) {
            case (.current?, .other(let subject)?):
                L10n.formatted("You made %@ an admin", subject)
            case (.other(let actor)?, .current?):
                L10n.formatted("%@ made you an admin", actor)
            case (.other(let actor)?, .other(let subject)?):
                L10n.formatted("%@ made %@ an admin", actor, subject)
            case (_, .current?):
                L10n.string("You were made an admin")
            case (_, .other(let subject)?):
                L10n.formatted("%@ was made an admin", subject)
            case (_, nil):
                nil
            }
        }

        private func adminRemovedText(actor: Participant?, subject: Participant?) -> String? {
            switch (actor, subject) {
            case (.current?, .other(let subject)?):
                L10n.formatted("You removed %@ as admin", subject)
            case (.other(let actor)?, .current?):
                L10n.formatted("%@ removed you as admin", actor)
            case (.other(let actor)?, .other(let subject)?):
                L10n.formatted("%@ removed %@ as admin", actor, subject)
            case (_, .current?):
                L10n.string("You are no longer an admin")
            case (_, .other(let subject)?):
                L10n.formatted("%@ is no longer an admin", subject)
            case (_, nil):
                nil
            }
        }

        private func groupRenamedText(actor: Participant?, groupName: String?) -> String {
            guard let groupName else { return L10n.string("Group renamed") }
            switch actor {
            case .current?:
                return L10n.formatted("You changed the group name to %@", groupName)
            case .other(let actor)?:
                return L10n.formatted("%@ changed the group name to %@", actor, groupName)
            case nil:
                return L10n.formatted("Group renamed to %@", groupName)
            }
        }

        private func groupAvatarChangedText(actor: Participant?) -> String {
            switch actor {
            case .current?:
                L10n.string("You changed the group photo")
            case .other(let actor)?:
                L10n.formatted("%@ changed the group photo", actor)
            case nil:
                L10n.string("Group avatar changed")
            }
        }

        private func trimmed(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func sanitizedFallback(_ value: String?) -> String? {
            guard let value = trimmed(value) else { return nil }
            return ContentSanitizer.compactSingleLine(value, maxLength: ContentSanitizer.maxGroupNameLength)
        }

        private func normalizedHex(_ value: String?) -> String? {
            guard let value = trimmed(value) else { return nil }
            return Hex.normalized32Bytes(value)
        }

        private func disappearingTimerText(
            actor: Participant?,
            oldRetentionSeconds: UInt64?,
            newRetentionSeconds: UInt64
        ) -> String {
            if newRetentionSeconds == 0 {
                switch actor {
                case .current?:
                    return L10n.string("You turned off disappearing messages")
                case .other(let actor)?:
                    return L10n.formatted("%@ turned off disappearing messages", actor)
                case nil:
                    return L10n.string("Disappearing messages turned off")
                }
            }

            let newText = GroupSystemEventPresentation.retentionDurationText(seconds: newRetentionSeconds)
            if let oldRetentionSeconds,
               oldRetentionSeconds > 0,
               oldRetentionSeconds != newRetentionSeconds {
                let oldText = GroupSystemEventPresentation.retentionDurationText(seconds: oldRetentionSeconds)
                switch actor {
                case .current?:
                    return L10n.formatted(
                        "You changed disappearing messages from %@ to %@",
                        oldText,
                        newText
                    )
                case .other(let actor)?:
                    return L10n.formatted(
                        "%@ changed disappearing messages from %@ to %@",
                        actor,
                        oldText,
                        newText
                    )
                case nil:
                    return L10n.formatted(
                        "Disappearing messages changed from %@ to %@",
                        oldText,
                        newText
                    )
                }
            }

            switch actor {
            case .current?:
                return L10n.formatted("You set disappearing messages to %@", newText)
            case .other(let actor)?:
                return L10n.formatted("%@ set disappearing messages to %@", actor, newText)
            case nil:
                return L10n.formatted("Disappearing messages set to %@", newText)
            }
        }
    }
}

/// How a kind-1210 preview names people outside the conversation store. The
/// resolver and the local account travel together because a row names both an
/// actor and a subject, either of which can be the reader.
nonisolated struct GroupSystemEventNaming {
    /// No profile lookup available: participants render as short npubs, or as
    /// localized generic copy when a payload's key is malformed.
    static let unresolvedIdentities = GroupSystemEventNaming(
        currentAccountIdHex: nil,
        displayName: { IdentityPresentation.text(accountIdHex: $0) }
    )

    let currentAccountIdHex: String?
    let displayName: GroupSystemEventPresentation.DisplayNameResolver
}
