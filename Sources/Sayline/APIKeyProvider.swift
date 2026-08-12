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
///
/// `hasResolved` is tracked separately from `cachedKey` deliberately: a
/// plain `String?` cache can't tell "never checked" apart from "checked
/// and got nothing" (e.g. a denied/interrupted prompt) — both look like
/// nil. Without the separate flag, a single denied prompt would never
/// "stick" as cached, so the very next call (we make two per dictation)
/// retries from scratch and prompts again — a real retry-storm bug found
/// via live testing, not hypothetical.
enum APIKeyProvider {
    /// Why a key could not be used, when one is plainly stored.
    ///
    /// Ad-hoc signing gives every rebuild a different code identity, so a
    /// Keychain item saved by an earlier build is present but unreadable by
    /// this one. The honest sentence is "re-enter it", not "you have none".
    static var lastFailureWasUnreadable = false

    private static var hasResolved = false
    private static var cachedKey: String?

    static var groqAPIKey: String? {
        if hasResolved {
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
        lastFailureWasUnreadable = resolved == nil && KeychainStore.itemExists()
        if lastFailureWasUnreadable {
            SaylineLog.log("a Groq key is stored but this build cannot read it — "
                + "ad-hoc signing changes the app's identity on every rebuild, "
                + "so the Keychain treats it as a different app. Re-save it in Settings.")
        }

        cachedKey = resolved
        hasResolved = true
        return resolved
    }

    /// Call after the user saves a new key in Settings so the fresh value
    /// takes effect immediately instead of waiting for the next launch.
    static func invalidateCache() {
        hasResolved = false
        cachedKey = nil
        hasResolvedOpenAI = false
        cachedOpenAIKey = nil
        hasResolvedYouTube = false
        cachedYouTubeKey = nil
    }

    private static var hasResolvedOpenAI = false
    private static var cachedOpenAIKey: String?
    private static var hasResolvedYouTube = false
    private static var cachedYouTubeKey: String?

    /// Used only to turn "play X on YouTube" into a real video, so its
    /// absence degrades to opening the search page rather than failing.
    static var youTubeAPIKey: String? {
        if hasResolvedYouTube { return cachedYouTubeKey }
        let resolved: String?
        if let stored = KeychainStore.load(.youTube), !stored.isEmpty {
            resolved = stored
        } else if let envKey = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"], !envKey.isEmpty {
            resolved = envKey
        } else {
            resolved = nil
        }
        cachedYouTubeKey = resolved
        hasResolvedYouTube = true
        return resolved
    }

    /// Used by the agent router while it runs on OpenAI. Same
    /// Keychain-then-environment order and same caching rationale as the
    /// Groq key above.
    static var openAIAPIKey: String? {
        if hasResolvedOpenAI {
            return cachedOpenAIKey
        }
        let resolved: String?
        if let stored = KeychainStore.load(.openAI), !stored.isEmpty {
            resolved = stored
        } else if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
            resolved = envKey
        } else {
            resolved = nil
        }
        cachedOpenAIKey = resolved
        hasResolvedOpenAI = true
        return resolved
    }
}
