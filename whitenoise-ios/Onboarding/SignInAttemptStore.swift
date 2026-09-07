import Foundation

@MainActor
final class SignInAttemptStore {
    private static let key = "marmot.signInAwaitingOpenChats"
    private let defaults: UserDefaults
    private(set) var accountIDs: Set<String>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        accountIDs = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    // This is an activation gate, not saved UI progress or permission to resume.
    func begin(_ id: String) { accountIDs.insert(id); save() }
    func finish(_ id: String) { accountIDs.remove(id); save() }
    func reset() { accountIDs.removeAll(); defaults.removeObject(forKey: Self.key) }
    private func save() { defaults.set(accountIDs.sorted(), forKey: Self.key) }
}
