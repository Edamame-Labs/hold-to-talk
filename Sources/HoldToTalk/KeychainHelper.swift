import Foundation
import Security

/// Stores and retrieves API keys in the macOS Keychain.
enum KeychainHelper {
    private static let service = "com.holdtotalk.apikeys"
    private static let allowedAccounts: Set<String> = ["openai", "anthropic"]

    @discardableResult
    static func save(account: String, key: String) -> Bool {
        guard allowedAccounts.contains(account) else {
            debugLog("[holdtotalk] Keychain save rejected for unknown account.")
            return false
        }

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
            kSecAttrLabel as String: "Hold to Talk \(providerDisplayName(account: account)) API key",
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

    static func load(account: String) -> String? {
        guard allowedAccounts.contains(account) else { return nil }

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

    static func delete(account: String) {
        guard allowedAccounts.contains(account) else { return }

        let query = baseQuery(account: account)
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

    private static func providerDisplayName(account: String) -> String {
        switch account {
        case "openai":
            return "OpenAI"
        case "anthropic":
            return "Anthropic"
        default:
            return "cloud provider"
        }
    }
}
