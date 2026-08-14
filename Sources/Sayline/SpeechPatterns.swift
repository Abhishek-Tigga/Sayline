import Foundation

/// The deterministic half of Clean's grammar and number policy.
///
/// **Why code and not prompt.** Every FIX below deletes a word — "revert
/// back" loses "back", "the both teams" loses "the", "discussed about"
/// loses "about". `TranscriptCleanupValidator`'s contract is that the
/// LLM may not delete words, so when the model got these right the
/// validator dutifully put them back. That is not a bug in either piece:
/// it is what happens when a policy that requires deletion is expressed
/// as a request to a model that is not allowed to delete.
///
/// Observed live, 2026-08-14, B3 — the 8B model produced exactly the
/// wanted text and the validator undid it:
///
/// ```
/// llm      : Do one thing, just prepone the standup to 9:30 and inform both teams.
/// validated: Do one thing just prepone the standup to 9:30 and inform the both teams.
/// ```
///
/// So these run **after** validation, on the validated string. The
/// validator never sees them, its contract stays intact, and the
/// substitutions apply whether the model cooperated or not.
///
/// **Scope is closed.** This is the table the user legislated in Clean
/// round 1, and nothing else. Additions are a product decision, not a
/// tidy-up — see `review/LEDGER.md`.
enum SpeechPatterns {

    /// Phrasing that is identity, not error.
    ///
    /// Not enforced here — nothing in this file touches them — but named
    /// so the list is greppable from one place, and because the prompt
    /// must protect them explicitly: a better cleanup model will itch to
    /// "fix" all three, and the model is the layer we do not control.
    static let protectedPhrases = ["prepone", "do one thing", "you please"]

    /// FIX, exactly as legislated. Order matters where one pattern's
    /// output could feed another's input; none currently do, and the
    /// tests pin that.
    ///
    /// `revert back` → `revert` keeps the speaker's verb on purpose. The
    /// obvious "improvement" is "get back to me", and the user ruled
    /// against substituting their verb.
    private static let substitutions: [(pattern: String, replacement: String)] = [
        // "I don't think so caching is the issue" → "I don't think caching…"
        // The apostrophe class carries U+2019 as well as ASCII: Whisper
        // emits the curly form routinely, and a rule that only knows the
        // straight one fires on half the real transcripts.
        ("(?i)\\b(i\\s+do\\s+n[o'\u{2019}]t\\s+think|i\\s+don['\u{2019}]?t\\s+think)\\s+so\\b(?=\\s+\\w)", "$1"),
        (#"(?i)\brevert\s+back\b"#, "revert"),
        (#"(?i)\bdiscussed\s+about\b"#, "discussed"),
        (#"(?i)\bdiscuss\s+about\b"#, "discuss"),
        // "the both teams" → "both teams"
        (#"(?i)\bthe\s+both\b"#, "both"),
        // "Myself, I will handle" / "Myself I will handle" → "I'll handle"
        (#"(?i)\bmyself,?\s+i\s+will\b"#, "I'll"),
        (#"(?i)\bmyself,?\s+i\s+wi?ll\b"#, "I'll"),
    ]

    /// PREFER contractions. Only forms with no ambiguity: "I will" → "I'll"
    /// is safe, "he is" → "he's" collides with possessives often enough in
    /// transcripts that it stays out.
    private static let contractions: [(pattern: String, replacement: String)] = [
        (#"(?i)\byou\s+have\b(?=\s+(been|got|to|a|an|the|already))"#, "you've"),
        (#"(?<![A-Za-z])I\s+will\b"#, "I'll"),
        (#"(?i)\bit\s+is\b(?=\s+(a|an|the|not|still|already|probably))"#, "it's"),
    ]

    /// Applies the policy. Idempotent — running it twice changes nothing,
    /// which the suite pins, because it runs on a string that may already
    /// have been through a cooperative model.
    static func apply(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in substitutions + contractions {
            out = replace(out, pattern, replacement)
        }
        return normalizeNumbers(out)
    }

    // MARK: - Numbers

    /// Spoken money and spacing artifacts, small and deterministic.
    ///
    /// "forty seven and a half thousand" → 47,500 mirrors `FactGuard`'s
    /// scale-word handling deliberately: that file learned on 2026-08-14
    /// that a spoken figure and its written form must reconcile, and the
    /// half-thousand is the same lexicon one step further. Kept as its own
    /// implementation rather than importing the guard, because the guard
    /// *recognises* numbers and this *rewrites* them — one is a reader and
    /// one is a writer, and fusing them would give the guard an opinion
    /// about output.
    static func normalizeNumbers(_ text: String) -> String {
        var out = text

        // "40 000" / "40 000" (thin space) → "40,000". Digit-space-triple
        // only, so "in 2024 15 people" is untouched: the trailing group
        // must be exactly three digits and not be followed by more.
        out = replace(out, #"(?<!\d)(\d{1,3})[  ](\d{3})(?!\d)"#, "$1,$2")

        // The number-word run is built from the lexicon below rather than
        // written as `\w+`. With `\w+` the engine takes the leftmost
        // match and hands back "budget is forty seven", `spokenValue`
        // rejects it, and the rule silently never fires — safe, and
        // useless. Alternation cannot over-reach.
        let num = (tens.keys.sorted() + units.keys.sorted()).joined(separator: "|")
        let run = "(?:\(num))(?:[\\s-](?:\(num))){0,3}"
        let scales = "thousand|lakh|crore|million"

        // "forty seven and a half thousand" → 47,500
        out = replace(out, "(?i)\\b(\(run))\\s+and\\s+a\\s+half\\s+(\(scales))\\b") { m in
            guard let base = spokenValue(m[1]), let scale = scaleValue(m[2].lowercased())
            else { return m[0] }
            return group(base * scale + scale / 2)
        }

        // "forty seven thousand" → 47,000, once the half-form has had its turn.
        out = replace(out, "(?i)\\b(\(run))\\s+(\(scales))\\b") { m in
            guard let base = spokenValue(m[1]), let scale = scaleValue(m[2].lowercased())
            else { return m[0] }
            return group(base * scale)
        }
        return out
    }

    private static func scaleValue(_ word: String) -> Int? {
        ["thousand": 1_000, "lakh": 100_000, "crore": 10_000_000, "million": 1_000_000][word]
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// "forty seven" → 47. Returns nil for anything that is not wholly a
    /// spoken number, so a non-match leaves the text alone rather than
    /// guessing.
    private static func spokenValue(_ phrase: String) -> Int? {
        let words = phrase.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard !words.isEmpty else { return nil }
        var total = 0
        for word in words {
            if let t = tens[word] { total += t }
            else if let u = units[word] { total += u }
            else if let d = Int(word) { total += d }
            else { return nil }
        }
        return total
    }

    /// Three-digit grouping, pinned to a fixed locale.
    ///
    /// `NumberFormatter` follows the machine's locale by default, and this
    /// machine's is Indian — so "two and a half lakh" formatted as
    /// `2,50,000` here and would have been `250,000` on a US machine. The
    /// same build producing different text depending on who ran it is a
    /// bug regardless of which grouping is nicer.
    ///
    /// Pinned to three-digit grouping because that is what the user's own
    /// expected outputs use (`47,500`, `40,000`) — though both systems
    /// agree at those magnitudes, so this only really decides the lakh
    /// case. Whether Indian grouping should be offered is a product
    /// question, recorded in `BACKLOG.md`, not something to settle by
    /// inheriting a system setting.
    private static func group(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Regex helpers

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Match-by-match replacement, for the cases where the replacement is
    /// computed rather than a template.
    private static func replace(_ text: String, _ pattern: String,
                                _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var out = text
        for match in matches.reversed() {
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                guard let r = Range(match.range(at: i), in: text) else { groups.append(""); continue }
                groups.append(String(text[r]))
            }
            guard let whole = Range(match.range, in: out) else { continue }
            out.replaceSubrange(whole, with: transform(groups))
        }
        return out
    }
}
