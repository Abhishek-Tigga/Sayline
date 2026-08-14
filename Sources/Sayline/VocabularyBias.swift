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
        let entries = assemble(myWords: myWords,
                               contactFirstNames: contactFirstNames,
                               appNames: appNames,
                               historyText: historyText,
                               isKnownWord: isKnownWord)
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
