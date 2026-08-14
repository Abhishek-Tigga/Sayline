import Foundation

/// Assembles the transcription vocabulary hint — the deterministic core
/// of `DESIGN-vocabulary-biasing.md`, kept Foundation-only so
/// `eval/bias-checks` can compile it bare.
///
/// The ladder (decision 2): the user's own typed words always enter,
/// then contact first names ranked by the user's dictation history
/// (decision 3), then app names that spelling doesn't already know —
/// "Safari" needs no help, "Figma" does. One list, applied everywhere
/// (decision 4). Sources rank contacts; they never add words — a
/// misheard name matches no contact and therefore ranks nothing, which
/// is what keeps the reinforcement loop from decision 1 impossible.
enum VocabularyBias {
    /// Whisper's prompt budget is ~224 tokens. The estimate below is
    /// crude (chars/4), so the cap stays conservative: an overrun is
    /// silently truncated by the model, which would drop the *end* of
    /// the list — the apps — in an order nobody chose.
    static let tokenBudget = 200

    /// The glossary line as sent, or nil when there is nothing to say.
    /// One fixed template (decision 7): Whisper treats its prompt as
    /// style precedent as well as vocabulary, so the phrasing is part
    /// of the eval'd surface and must not vary.
    static func glossary(myWords: [String],
                         contactFirstNames: [String],
                         appNames: [String],
                         historyText: String,
                         isKnownWord: (String) -> Bool) -> String? {
        glossaryLine(assemble(myWords: myWords,
                              contactFirstNames: contactFirstNames,
                              appNames: appNames,
                              historyText: historyText,
                              isKnownWord: isKnownWord))
    }

    /// The template applied to an already-assembled list — split out so
    /// the builder can keep the entries (the echo guard needs them) and
    /// the line without two copies of the phrasing.
    static func glossaryLine(_ entries: [String]) -> String? {
        guard !entries.isEmpty else { return nil }
        return "Glossary: " + entries.joined(separator: ", ")
    }

    /// The ladder itself, exposed for the checks: ordered, deduplicated,
    /// budget-capped entries.
    static func assemble(myWords: [String],
                         contactFirstNames: [String],
                         appNames: [String],
                         historyText: String,
                         isKnownWord: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        var entries: [String] = []
        // "Glossary: " plus separators; counted against the budget so
        // the cap bounds what is actually sent, not just the words.
        var spentTokens = estimateTokens("Glossary: ")

        func admit(_ word: String) {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            let cost = estimateTokens(trimmed + ", ")
            guard spentTokens + cost <= tokenBudget else { return }
            seen.insert(key)
            entries.append(trimmed)
            spentTokens += cost
        }

        // Rung 1: typed words. Highest intent, first in, order kept.
        myWords.forEach(admit)

        // Rung 2: contact first names, the ones the user actually says
        // first. History *ranks*, it never adds (decision 3) — and the
        // sort is stable, so unmentioned contacts keep their original
        // order rather than an arbitrary one.
        let counts = wordCounts(of: historyText)
        let ranked = contactFirstNames.enumerated().sorted {
            let a = counts[$0.element.lowercased(), default: 0]
            let b = counts[$1.element.lowercased(), default: 0]
            return a == b ? $0.offset < $1.offset : a > b
        }
        ranked.forEach { admit($0.element) }

        // Rung 3: app names spelling doesn't know. An app whose every
        // word is a dictionary word ("Notes", "Final Cut Pro") is
        // skipped — the model already knows those words, and a slot
        // spent on one is a slot wasted (decision 2).
        for app in appNames {
            let words = app.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            guard !words.isEmpty else { continue }
            if words.allSatisfy({ isKnownWord(String($0).lowercased()) }) { continue }
            admit(app)
        }

        return entries
    }

    /// ~4 characters per token — crude on purpose; the conservative
    /// budget above absorbs the error.
    static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    /// True when a transcript is Whisper reading our own hint list back
    /// instead of transcribing — observed live 2026-08-14, when an echo
    /// opened seven apps and sent the agent to vodka.com.
    ///
    /// Deliberately structural, with NO loudness gate: both observed
    /// echoes had peaks of 0.08 and 1.0 (a breath or desk tap pegs the
    /// meter), so unlike `WhisperHallucination` there is no quiet band
    /// to lean on. Two signals, either sufficient:
    ///
    /// 1. The word "glossary" — the template's own label — appearing
    ///    twice, or opening the transcript alongside a list entry.
    ///    Nobody dictates our template word twice; an echo repeats it.
    ///    A single mention in real speech ("add a glossary to the doc")
    ///    passes untouched.
    /// 2. Three or more entries appearing in the transcript in the
    ///    list's own order, each one the list-neighbor of the last.
    ///    "Open Figma and WhatsApp" names two, not neighbors — passes.
    ///    "…Microsoft Word, Muesli, Numbers, OneDrive…" is the list
    ///    reciting itself — no one speaks three consecutive items of an
    ///    alphabetical list they have never seen.
    static func looksLikeEcho(transcript: String, entries: [String]) -> Bool {
        guard !entries.isEmpty else { return false }
        let words = tokens(of: transcript)
        guard !words.isEmpty else { return false }

        let glossaryMentions = words.filter { $0 == "glossary" }.count

        // Every occurrence of every entry, as (position in transcript,
        // index in the glossary), in transcript order.
        var hits: [(position: Int, entry: Int)] = []
        for (entryIndex, entry) in entries.enumerated() {
            let entryWords = tokens(of: entry)
            guard !entryWords.isEmpty,
                  words.count >= entryWords.count else { continue }
            for start in 0...(words.count - entryWords.count) {
                if Array(words[start..<start + entryWords.count]) == entryWords {
                    hits.append((start, entryIndex))
                }
            }
        }
        hits.sort { $0.position < $1.position }

        if glossaryMentions >= 2 { return true }
        if glossaryMentions >= 1, words.first == "glossary", !hits.isEmpty { return true }

        var run = 1
        var longestRun = hits.isEmpty ? 0 : 1
        for i in 1..<max(1, hits.count) where i < hits.count {
            run = hits[i].entry == hits[i - 1].entry + 1 ? run + 1 : 1
            longestRun = max(longestRun, run)
        }
        return longestRun >= 3
    }

    private static func tokens(of text: String) -> [String] {
        var words: [String] = []
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word); word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    private static func wordCounts(of text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                counts[word, default: 0] += 1
                word = ""
            }
        }
        if !word.isEmpty { counts[word, default: 0] += 1 }
        return counts
    }
}
