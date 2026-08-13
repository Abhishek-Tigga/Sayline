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

    /// Returns whether the value is actually retrievable afterwards.
    ///
    /// Both halves of that sentence were missing. `SecItemAdd`'s OSStatus
    /// was discarded entirely, so a failed save was indistinguishable from
    /// a successful one: Settings accepted the key, said nothing, and
    /// dictation then failed with "No Groq API key set". The user re-entered
    /// the key believing it had been stored, twice.
    ///
    /// Reported 2026-08-14, with `OPENAI_API_KEY` and `YOUTUBE_API_KEY`
    /// sitting healthily in the same service — so this was never keychain
    /// access in general, only this write silently going nowhere.
    ///
    /// Success is defined as reading the value back, not as `SecItemAdd`
    /// returning 0. A write that reports success but cannot be read is the
    /// failure this is meant to catch.
    @discardableResult
    static func save(_ value: String, for key: Key = .groq) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        // Update first, add only if there is nothing to update — Fable's
        // shape, 2026-08-14, replacing delete-then-add.
        //
        // Delete-then-add threw away the item's ACL continuity on every
        // save and could leave the worst possible middle state: delete
        // reports success, add then collides with something the default
        // query cannot see, and the key is gone with a "saved" on screen.
        // Update keeps the existing item and its access control intact.
        let update = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        var status = update
        if update == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            // Two codes worth recognising on sight, per Fable:
            //  -25299 duplicate the default query cannot see — usually an
            //         iCloud-synchronised ghost, which matches an add but
            //         not a delete. Retry with kSecAttrSynchronizableAny.
            //  -25293 an ACL orphan from the signing transition. That is
            //         the one case where deleting and replacing is right,
            //         and it should be the user's explicit choice.
            SaylineLog.log("KEYCHAIN SAVE FAILED for \(key.rawValue) -> OSStatus \(status) "
                + "(\(message(status))). The key was NOT stored."
                + (status == -25299 ? " -25299: a hidden duplicate, likely an iCloud-synced ghost." : "")
                + (status == -25293 ? " -25293: an ACL orphan; the item needs replacing deliberately." : ""))
            return false
        }

        guard load(key) == value else {
            SaylineLog.log("KEYCHAIN SAVE UNVERIFIABLE for \(key.rawValue): the write reported "
                + "success but the value could not be read back.")
            return false
        }
        SaylineLog.log("keychain saved \(key.rawValue) and read it back")
        return true
    }

    private static func message(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "no description"
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
