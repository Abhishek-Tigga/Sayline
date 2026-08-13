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
            // -25293 (errSecAuthFailed) used to be treated as "this entry
            // belongs to an older build" and the entry was DELETED here.
            //
            // That is removed, and the reason it existed is gone. It was
            // written when the app was ad-hoc signed, so every rebuild
            // produced a new code signature and genuinely orphaned the
            // item. Since the Apple Development identity landed
            // (2026-08-13) the signature is stable across rebuilds, and
            // deleting on a failed read became pure downside: any transient
            // refusal silently destroys the user's API key.
            //
            // It did exactly that on 2026-08-14 at 02:55. The key had been
            // working minutes earlier; one failed read during a rebuild
            // wiped it, dictation stopped with "No Groq API key set", and
            // the log line blamed "an older build" — which was no longer
            // true and sent the diagnosis the wrong way.
            //
            // An unreadable item is now reported, not destroyed. Re-entering
            // the key still works regardless, because `save` deletes before
            // writing. Deleting a credential is the user's call to make.
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                SaylineLog.log("keychain entry for \(key.rawValue) exists but cannot be read "
                    + "-> OSStatus \(status). NOT deleting it. Re-enter the key in Settings to "
                    + "replace it, or unlock the login keychain if it is locked.")
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
