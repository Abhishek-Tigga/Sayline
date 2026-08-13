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
        case youTube = "YOUTUBE_API_KEY"
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
        guard status == errSecSuccess, let data = result as? Data else {
            // Silence here cost a live debugging session on 2026-08-12: the
            // key was plainly in the Keychain, every read returned nil, and
            // nothing said why. The status code is the whole diagnosis —
            // -25300 means no such item, -25308 means the user or the
            // system refused without a prompt, and 0 with no data means
            // something else entirely.
            // An item we cannot unlock is worse than no item.
            //
            // -25293 (errSecAuthFailed) means the entry exists but belongs
            // to a different build: macOS binds a Keychain item to the code
            // signature that created it, and ad-hoc signing gives every
            // rebuild a new one. The stale entry then sits there refusing
            // every read, and re-entering the key in Settings only works
            // because `save` deletes first — so the user pays a dialog and
            // a re-entry for something the app could clear itself.
            //
            // Deleting it here makes the next save unambiguous and stops
            // the app prompting for a passphrase it can never accept.
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                SaylineLog.log("keychain entry for \(key.rawValue) belongs to an older build — "
                    + "removing it so re-entering the key works cleanly")
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key.rawValue,
                ] as CFDictionary)
            } else if status != errSecItemNotFound {
                SaylineLog.log("keychain read for \(key.rawValue) failed -> OSStatus \(status) "
                    + "(\(SecCopyErrorMessageString(status, nil) as String? ?? "no description"))")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an item exists at all, regardless of whether we may read it.
    ///
    /// The two are different and the difference is the whole message. Under
    /// ad-hoc signing every rebuild is a new application as far as the
    /// Keychain is concerned, so an item saved by yesterday's build is
    /// present but unreadable by today's — and telling someone "no key set"
    /// when their key is plainly there sends them to look in the wrong
    /// place.
    ///
    /// Asks only for the attributes, never the data, so it cannot itself
    /// trigger a prompt.
    static func itemExists(_ key: Key = .groq) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
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
