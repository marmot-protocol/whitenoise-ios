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
        if let payloadData = root["data"] as? [String: Any] {
            actor = payloadData["actor"] as? String
            subject = payloadData["subject"] as? String
            name = payloadData["name"] as? String
        }

        return Payload(
            text: root["text"] as? String,
            systemType: root["system_type"] as? String,
            actor: actor,
            subject: subject,
            name: name
        )
    }

    private struct Payload {
        var text: String?
        var systemType: String?
        var actor: String?
        var subject: String?
        var name: String?

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
                default:
                    break
                }
            }

            if let text = trimmed(text) { return text }
            if let systemType = trimmed(systemType) {
                let phrase = systemType.replacingOccurrences(of: "_", with: " ")
                return phrase.prefix(1).uppercased() + phrase.dropFirst()
            }
            return nil
        }

        private func trimmed(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func normalizedHex(_ value: String?) -> String? {
            guard let value = trimmed(value) else { return nil }
            return value.lowercased()
        }
    }
}
