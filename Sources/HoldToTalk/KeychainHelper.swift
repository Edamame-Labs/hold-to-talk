import Foundation
import Security

/// Stores and retrieves API keys in the macOS Keychain.
enum KeychainHelper {
    private static let service = "com.holdtotalk.apikeys"

    @discardableResult
    static func save(provider: CloudProvider, key: String) -> Bool {
        let account = provider.rawValue
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmedKey.utf8)

        // Remove any existing item first.
        let deleteQuery = baseQuery(account: account)
        SecItemDelete(deleteQuery as CFDictionary)

        guard !trimmedKey.isEmpty else { return true } // treat empty string as deletion

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: "Hold to Talk \(provider.displayName) API key",
            kSecAttrDescription as String: "API key used by Hold to Talk cloud features.",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            debugLog("[holdtotalk] Keychain save failed for \(account): OSStatus \(status)")
            return false
        }
        return true
    }

    static func load(provider: CloudProvider) -> String? {
        let account = provider.rawValue
        var query = baseQuery(account: account)
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(provider: CloudProvider) {
        let query = baseQuery(account: provider.rawValue)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
