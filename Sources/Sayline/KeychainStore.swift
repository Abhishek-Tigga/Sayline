import Foundation
import Security

/// Minimal wrapper around the macOS Keychain for API keys — never written
/// to disk in plaintext, never committed anywhere. Keys live here during
/// development; the shipping product proxies through its own backend and
/// never asks a user for one (see PRODUCT.md).
enum KeychainStore {
    enum Key: String {
        case groq = "GROQ_API_KEY"
        case openAI = "OPENAI_API_KEY"
    }

    private static let service = "com.abhishektigga.sayline"

    static func save(_ value: String, for key: Key = .groq) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data
        SecItemAdd(newItem as CFDictionary, nil)
    }

    static func load(_ key: Key = .groq) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: Key = .groq) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
