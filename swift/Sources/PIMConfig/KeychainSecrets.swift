import Foundation
import Security

public enum KeychainSecretsError: Error, CustomStringConvertible {
    case unexpectedStatus(OSStatus, operation: String)

    public var description: String {
        switch self {
        case .unexpectedStatus(let status, let operation):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(message)"
        }
    }
}

/// Secrets in the user's login keychain, one generic password per dotted key
/// (service `apple-pim`, account = key).
///
/// The login keychain rather than the data protection keychain: the latter
/// requires an application-identifier entitlement, which a command-line tool
/// can't carry without a provisioning profile. The item's access list trusts the
/// binary that created it by designated requirement, so a Developer ID signed
/// mail-cli keeps access across rebuilds; an ad-hoc build is re-prompted.
public enum KeychainSecrets {
    /// Override for tests via `APPLE_PIM_KEYCHAIN_SERVICE`, so they never touch real items.
    public static var service: String {
        if let s = ProcessInfo.processInfo.environment["APPLE_PIM_KEYCHAIN_SERVICE"], !s.isEmpty {
            return s
        }
        return "apple-pim"
    }

    public static func read(_ key: String) throws -> String? {
        try SecretsStore.validateKey(key)
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainSecretsError.unexpectedStatus(status, operation: "read of '\(key)'")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func write(_ key: String, value: String) throws {
        try SecretsStore.validateKey(key)
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            baseQuery(key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainSecretsError.unexpectedStatus(status, operation: "update of '\(key)'")
        }
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "apple-pim \(key)"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecretsError.unexpectedStatus(addStatus, operation: "add of '\(key)'")
        }
    }

    @discardableResult
    public static func delete(_ key: String) throws -> Bool {
        try SecretsStore.validateKey(key)
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainSecretsError.unexpectedStatus(status, operation: "delete of '\(key)'")
        }
        return true
    }

    public static func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainSecretsError.unexpectedStatus(status, operation: "list")
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
