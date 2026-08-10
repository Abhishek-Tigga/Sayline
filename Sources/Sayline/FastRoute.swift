import Foundation

/// Answers the easy commands without asking a model.
///
/// Every agent command currently pays a round trip to OpenAI — a measured
/// 1,000–1,400 ms, and that is the floor rather than the tail. A third of
/// them do not need intelligence: "open Safari", "lock the screen",
/// "what's my battery" are lookups against tables this app already owns,
/// and it already consults those tables *after* the model answers.
///
/// So this tries first, and returns nil for anything it is not certain
/// about. The router is unchanged and still handles everything else; the
/// only difference is that some commands stop waiting for it.
///
/// Two rules keep it honest.
///
/// **Whole utterance only.** "Open Safari" matches; "Open Safari and check
/// my battery" must not, or the fast path silently drops half of what was
/// asked. This is the same guard `VoiceCommand` needed after "scratch that
/// idea" scored 0.94 against "scratch that" and nearly deleted real work —
/// a matcher that fires on part of a sentence is a matcher that eats the
/// rest of it.
///
/// **Certain or nothing.** No fuzzy matching, no near-misses. Ambiguity is
/// the model's job, and a wrong answer delivered instantly is worse than a
/// right one delivered in a second.
enum FastRoute {
    static func action(for transcript: String) -> AgentAction? {
        let text = normalize(transcript)
        guard !text.isEmpty else { return nil }

        if let action = fixedCommand(text) { return action }
        if let action = systemQuery(text) { return action }
        if let action = appCommand(text) { return action }
        return nil
    }

    // MARK: - Normalising

    /// Lowercases, drops punctuation and the politeness people put around
    /// commands, so "Please open Safari." and "open safari" are one thing.
    private static func normalize(_ transcript: String) -> String {
        // Apostrophes are removed rather than split on, so "what's" reads
        // as one word. Splitting made it "what s", which matched nothing
        // and quietly sent every contraction to the model.
        var words = transcript.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let leading: Set<String> = ["please", "hey", "ok", "okay", "sayline", "can", "you", "could"]
        while let first = words.first, leading.contains(first) { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        return words.joined(separator: " ")
    }

    // MARK: - No arguments

    private static let fixed: [(phrases: Set<String>, action: AgentAction)] = [
        (["lock the screen", "lock screen", "lock my screen", "lock my mac", "lock the mac"], .lockScreen),
        (["empty the trash", "empty trash", "empty the bin"], .emptyTrash),
        (["take a screenshot", "screenshot", "take screenshot", "grab a screenshot"], .takeScreenshot),
        (["mute", "mute the volume", "mute volume", "mute the sound"], .setVolume(.mute)),
        (["unmute", "unmute the volume", "unmute volume", "unmute the sound"], .setVolume(.unmute)),
        (["volume up", "turn the volume up", "turn up the volume", "louder"], .setVolume(.up)),
        (["volume down", "turn the volume down", "turn down the volume", "quieter"], .setVolume(.down)),
        (["turn on dark mode", "enable dark mode", "dark mode on", "switch to dark mode"], .setDarkMode(enabled: true)),
        (["turn off dark mode", "disable dark mode", "dark mode off", "switch to light mode"], .setDarkMode(enabled: false)),
        (["turn on wifi", "turn wifi on", "enable wifi", "turn on wi fi", "turn wi fi on"], .setWiFi(enabled: true)),
        (["turn off wifi", "turn wifi off", "disable wifi", "turn off wi fi", "turn wi fi off"], .setWiFi(enabled: false)),
    ]

    private static func fixedCommand(_ text: String) -> AgentAction? {
        for entry in fixed where entry.phrases.contains(text) {
            return entry.action
        }
        return nil
    }

    // MARK: - Questions about this Mac

    private static let queries: [(phrases: Set<String>, query: AgentAction.SystemQuery)] = [
        (["what is my battery", "whats my battery", "battery", "battery level",
          "how much battery do i have", "what is my battery level",
          "whats my battery level", "how is my battery"], .battery),
        (["how much storage do i have", "storage", "disk space", "free space",
          "how much disk space do i have", "how much space do i have"], .storage),
        (["how much memory do i have", "memory", "ram", "how much ram do i have"], .memory),
        (["how long has my mac been on", "uptime", "what is my uptime",
          "whats my uptime"], .uptime),
        (["what is my volume", "whats my volume", "volume level",
          "what is the volume", "whats the volume"], .volumeLevel),
        (["what version of macos am i on", "macos version", "what macos am i running",
          "what is my macos version", "whats my macos version"], .macOSVersion),
        (["what is playing", "whats playing", "what song is this",
          "what is playing right now", "now playing"], .nowPlaying),
    ]

    private static func systemQuery(_ text: String) -> AgentAction? {
        for entry in queries where entry.phrases.contains(text) {
            return .answerQuery(entry.query)
        }
        return nil
    }

    // MARK: - Opening and closing apps

    private static let openVerbs = ["open", "launch", "start", "open up"]
    private static let closeVerbs = ["close", "quit", "exit"]

    /// "open Safari" and "close Notes", but only when the name is an app
    /// that is actually installed and is not also a site we know.
    ///
    /// The website check is the important half. "Open Spotify" is genuinely
    /// ambiguous — there may be an app and there is certainly a site — and
    /// the model weighs that better than a lookup can. Anything ambiguous
    /// falls through rather than guessing.
    private static func appCommand(_ text: String) -> AgentAction? {
        for verb in openVerbs {
            if let name = argument(after: verb, in: text), let app = unambiguousApp(name) {
                return .openApp(name: app)
            }
        }
        for verb in closeVerbs {
            if let name = argument(after: verb, in: text), let app = unambiguousApp(name) {
                return .closeApp(name: app)
            }
        }
        return nil
    }

    /// Everything after the verb, with a leading article dropped. Returns
    /// nil when the sentence contains a conjunction, because "open Safari
    /// and lock the screen" is two commands and this only answers one.
    private static func argument(after verb: String, in text: String) -> String? {
        guard text.hasPrefix(verb + " ") else { return nil }
        var rest = String(text.dropFirst(verb.count + 1))
        for article in ["the ", "my ", "a "] where rest.hasPrefix(article) {
            rest = String(rest.dropFirst(article.count))
        }
        guard !rest.isEmpty else { return nil }
        let conjunctions = [" and ", " then ", " also ", " after ", " plus "]
        guard !conjunctions.contains(where: { rest.contains($0) }) else { return nil }
        if rest.hasSuffix(" app") { rest = String(rest.dropLast(4)) }
        return rest
    }

    private static func unambiguousApp(_ name: String) -> String? {
        guard let real = InstalledAppCatalog.realName(for: name) else { return nil }
        guard WebsiteCatalog.site(matching: name) == nil else { return nil }
        return real
    }
}
