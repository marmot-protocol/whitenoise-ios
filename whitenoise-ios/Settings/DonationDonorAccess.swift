import Foundation
import Security

nonisolated struct DonationAccessCredential: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: Date
}

@MainActor
protocol DonationAccessStoring: AnyObject {
    func load() throws -> DonationAccessCredential?
    func save(_ credential: DonationAccessCredential) throws
    func delete() throws
    func hasLostAccess() throws -> Bool
    func markLostAccess() throws
}

@MainActor
final class DonationKeychainAccessStore: DonationAccessStoring {
    private static let defaultService = "dev.ipf.whitenoise.donor-access"
    private let account: String
    private var service: String { Self.defaultService }

    init(environment: DonationBuildConfig.Environment) {
        account = environment.rawValue
    }

    static func eraseAllAppData(delete: (CFDictionary) -> OSStatus = SecItemDelete) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: defaultService
        ]
        let status = delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DonationAccessStoreError.unavailable
        }
    }

    func load() throws -> DonationAccessCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(DonationAccessCredential.self, from: data),
              !credential.token.isEmpty
        else { throw DonationAccessStoreError.unavailable }
        return credential
    }

    func save(_ credential: DonationAccessCredential) throws {
        guard !credential.token.isEmpty else { throw DonationAccessStoreError.unavailable }
        let data = try JSONEncoder().encode(credential)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw DonationAccessStoreError.unavailable }
        } else if status != errSecSuccess {
            throw DonationAccessStoreError.unavailable
        }
        let removed = SecItemDelete(lostAccessQuery as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else {
            throw DonationAccessStoreError.unavailable
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DonationAccessStoreError.unavailable
        }
    }

    func hasLostAccess() throws -> Bool {
        var query = lostAccessQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw DonationAccessStoreError.unavailable }
        return true
    }

    func markLostAccess() throws {
        try delete()
        var query = lostAccessQuery
        query[kSecValueData as String] = Data([1])
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw DonationAccessStoreError.unavailable
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private var lostAccessQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(account).lost"]
    }
}

nonisolated enum DonationAccessStoreError: Error, Sendable {
    case unavailable
}

nonisolated enum DonationAccessNonce {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DonationAccessStoreError.unavailable
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
