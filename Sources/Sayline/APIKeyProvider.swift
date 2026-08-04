import Foundation

/// Where Sayline looks for the user's Groq API key: Keychain first (the
/// real, user-facing path via Settings), falling back to the GROQ_API_KEY
/// environment variable (keeps our existing dev/testing workflow working
/// without needing to enter a key into the UI every time).
enum APIKeyProvider {
    static var groqAPIKey: String? {
        if let stored = KeychainStore.load(), !stored.isEmpty {
            return stored
        }
        if let envKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        return nil
    }
}
