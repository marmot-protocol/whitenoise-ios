import Foundation
import UIKit
@testable import whitenoise_ios

/// In-process stand-in for `UIPasteboard`. Real pasteboard calls are synchronous
/// IPC to `pasted`, which has blocked the MainActor for minutes on CI and timed
/// out unrelated MainActor tests. Mirrors the semantics `SensitiveClipboard`
/// relies on: every write advances `changeCount`, and expired items are unreadable.
final class InMemorySensitivePasteboard: SensitivePasteboard {
    private(set) var changeCount = 0
    private(set) var lastOptions: [UIPasteboard.OptionsKey: Any] = [:]
    private var storedItems: [[String: Any]] = []
    private var expirationDate: Date?

    var items: [[String: Any]] {
        get {
            if let expirationDate, expirationDate <= Date() { return [] }
            return storedItems
        }
        set { setItems(newValue, options: [:]) }
    }

    var string: String? {
        get { items.lazy.flatMap(\.values).compactMap { $0 as? String }.first }
        set { setItems(newValue.map { [[UIPasteboard.typeAutomatic: $0]] } ?? [], options: [:]) }
    }

    var hasStrings: Bool { string != nil }

    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
        storedItems = items
        expirationDate = options[.expirationDate] as? Date
        lastOptions = options
        changeCount += 1
    }
}
