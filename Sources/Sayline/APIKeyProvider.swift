import Foundation

/// Where Sayline looks for the user's Groq API key: Keychain first (the
/// real, user-facing path via Settings), falling back to the GROQ_API_KEY
/// environment variable (keeps our existing dev/testing workflow working
/// without needing to enter a key into the UI every time).
///
/// Caches the resolved key in memory after the first lookup — the key
/// doesn't change mid-session, and re-reading from Keychain on every API
/// call (transcription + cleanup, twice per dictation) triggers a macOS
/// Keychain access prompt each time with our current ad-hoc code signing.
enum APIKeyProvider {
    private static var cachedKey: String?

    static var groqAPIKey: String? {
        if let cachedKey {
            return cachedKey
        }

        let resolved: String?
        if let stored = KeychainStore.load(), !stored.isEmpty {
            resolved = stored
        } else if let envKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !envKey.isEmpty {
            resolved = envKey
        } else {
            resolved = nil
        }

        cachedKey = resolved
        return resolved
    }

    /// Call after the user saves a new key in Settings so the fresh value
    /// takes effect immediately instead of waiting for the next launch.
    static func invalidateCache() {
        cachedKey = nil
    }
}
