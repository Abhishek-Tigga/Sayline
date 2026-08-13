import Foundation

/// The deterministic half of work mode's safety contract.
///
/// Clean mode's promise is "never lose a word", which a rewrite cannot
/// keep. Work mode's promise instead is that the *facts* survive: every
/// number, day, name and negation you actually said is still there
/// afterwards, and nothing you would be held to appears that you never
/// said. Structure is completely free — that is the whole point of the
/// mode.
///
/// Used twice per dictation, and deliberately the same call both times:
/// once before the model, to list the facts in the prompt as
/// must-appear-verbatim, and once after, to check the result. One source,
/// so the prompt and the guard cannot drift apart — the failure mode that
/// has bitten this project repeatedly is two copies of one truth.
///
/// **No LLM anywhere in here.** A second model judging the first adds a
/// round trip and its own hallucinations; being dumb code is this thing's
/// only real virtue. It is allowed to be wrong in the safe direction —
/// see `resolved self-correction` in `eval/factguard-checks`, a known
/// false positive kept in the suite so nobody rediscovers it as a bug.
///
/// Foundation only, so a check suite can hold it without a build.
enum FactGuard {

    // MARK: - What counts as a fact

    struct FactSet: Equatable {
        /// Normalized to digits: "fifteen" and "15" are the same fact.
        var numbers: Set<Int> = []
        /// Lowercased day names.
        var days: Set<String> = []
        /// Capitalized words that look like names, lowercased for compare.
        var names: Set<String> = []
        /// How many negation markers the raw speech carried. A rewrite is
        /// free to rephrase them, not to drop them.
        var negationCount: Int = 0

        var isEmpty: Bool {
            numbers.isEmpty && days.isEmpty && names.isEmpty && negationCount == 0
        }
    }

    enum Violation: Equatable {
        /// A number that was said is missing from the rewrite.
        case numberLost(Int)
        /// A day that was said is missing.
        case dayLost(String)
        /// A name that was said is missing.
        case nameLost(String)
        /// The rewrite carries fewer negations than the speech did — the
        /// class that silently reverses meaning ("I don't think we should"
        /// becoming "we should").
        case negationLost(said: Int, kept: Int)
        /// A commitment the speaker never made. The model must never put
        /// the user on the hook for something.
        case inventedCommitment(String)

        /// One line, naming the broken fact, for the corrective retry and
        /// for the log. The retry is only useful if it says what to fix.
        var explanation: String {
            switch self {
            case .numberLost(let n): return "the number \(n) was dropped"
            case .dayLost(let d): return "the day \(d.capitalized) was dropped"
            case .nameLost(let n): return "the name \(n) was dropped"
            case .negationLost(let said, let kept):
                return "a negation was lost — the speech had \(said), the rewrite has \(kept)"
            case .inventedCommitment(let phrase):
                return "it added a commitment that was never spoken (\"\(phrase)\")"
            }
        }

        /// Coarse class for the log, so "does the guard fire too often"
        /// becomes a lookup rather than an argument.
        var kind: String {
            switch self {
            case .numberLost: return "number"
            case .dayLost: return "day"
            case .nameLost: return "name"
            case .negationLost: return "negation"
            case .inventedCommitment: return "invented-commitment"
            }
        }
    }

    // MARK: - Extraction

    static func extract(from raw: String) -> FactSet {
        var facts = FactSet()
        let words = tokenize(raw)

        facts.numbers = numbers(in: words)
        facts.days = Set(words.compactMap { dayNames.contains($0) ? $0 : nil })
        facts.names = properNouns(in: raw)
        facts.negationCount = words.filter(negationMarkers.contains).count
        return facts
    }

    /// The pinned-facts block for the prompt. Empty when there is nothing
    /// to pin, so a transcript of pure prose does not get a pointless
    /// header.
    static func promptBlock(for facts: FactSet) -> String {
        guard !facts.isEmpty else { return "" }
        var lines: [String] = []
        if !facts.numbers.isEmpty {
            lines.append("numbers: " + facts.numbers.sorted().map(String.init).joined(separator: ", "))
        }
        if !facts.days.isEmpty {
            lines.append("days: " + facts.days.sorted().map { $0.capitalized }.joined(separator: ", "))
        }
        if !facts.names.isEmpty {
            lines.append("names: " + facts.names.sorted().joined(separator: ", "))
        }
        if facts.negationCount > 0 {
            lines.append("negations: \(facts.negationCount) — do not reverse any statement")
        }
        return "These must appear unchanged in your reply:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Verification

    static func verify(raw facts: FactSet, rewrite: String) -> [Violation] {
        let words = tokenize(rewrite)
        let present = numbers(in: words)
        var violations: [Violation] = []

        for number in facts.numbers.sorted() where !present.contains(number) {
            violations.append(.numberLost(number))
        }
        let rewriteDays = Set(words.filter(dayNames.contains))
        for day in facts.days.sorted() where !rewriteDays.contains(day) {
            violations.append(.dayLost(day))
        }
        // Presence, not capitalization.
        //
        // Extraction uses a capital letter as the hint that a word might
        // be a name; verification must not, or every sentence-initial verb
        // becomes a name that the rewrite "dropped" by lowercasing it —
        // "Ship on Tuesday" rewritten as "…so we ship on Tuesday" is a
        // faithful rewrite and was being flagged. A genuinely dropped name
        // is absent from the text entirely, whatever its case.
        let rewriteWords = Set(words)
        for name in facts.names.sorted() where !rewriteWords.contains(name) {
            violations.append(.nameLost(name))
        }

        // Counted, not matched. Which words carry the negation is the
        // model's business — "I don't think we should" and "I think we
        // shouldn't" are both faithful. Losing one entirely is not.
        let keptNegations = words.filter(negationMarkers.contains).count
        if keptNegations < facts.negationCount {
            violations.append(.negationLost(said: facts.negationCount, kept: keptNegations))
        }

        // Invention is checked by the `raw:rewrite:` overload, which has
        // the original text. A FactSet has already thrown away the words.
        return violations
    }

    /// Full check including invention, which needs the original text
    /// rather than only the extracted facts.
    static func verify(raw: String, rewrite: String) -> [Violation] {
        var violations = verify(raw: extract(from: raw), rewrite: rewrite)
        let rawLower = raw.lowercased()
        let rewriteLower = rewrite.lowercased()
        for phrase in commitmentPhrases
        where rewriteLower.contains(phrase) && !rawLower.contains(phrase) {
            // "I will" said aloud and written "I'll" is the same promise,
            // so the equivalents are checked together before complaining.
            let equivalents = commitmentEquivalents[phrase] ?? []
            guard !equivalents.contains(where: rawLower.contains) else { continue }
            violations.append(.inventedCommitment(phrase))
        }
        return violations
    }

    // MARK: - Pieces

    private static let dayNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    /// Words that reverse meaning. "No" is included: "no, we shouldn't"
    /// carries the negation on its own.
    private static let negationMarkers: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "neither", "nor",
        "dont", "doesnt", "didnt", "wont", "wouldnt", "cant", "cannot",
        "couldnt", "shouldnt", "isnt", "arent", "wasnt", "werent", "havent",
        "hasnt", "hadnt", "aint",
    ]

    private static let commitmentPhrases: [String] = [
        "i'll", "i will", "i promise", "i guarantee", "we'll", "we will",
        "i commit", "you can count on",
    ]

    private static let commitmentEquivalents: [String: [String]] = [
        "i'll": ["i will", "i shall"],
        "i will": ["i'll", "i shall"],
        "we'll": ["we will"],
        "we will": ["we'll"],
    ]

    /// Words that start sentences and get capitalized without being names.
    /// Kept small on purpose: a false "name" costs a fallback, and a
    /// fallback costs the user nothing but their exact words.
    private static let notNames: Set<String> = [
        "i", "the", "a", "an", "and", "but", "so", "then", "this", "that",
        "these", "those", "it", "we", "they", "he", "she", "you", "if",
        "when", "what", "why", "how", "where", "who", "there", "here",
        "yes", "no", "ok", "okay", "let", "lets", "please", "thanks",
        "hi", "hey", "hello", "also", "just", "actually", "basically",
        // Contractions, apostrophe-stripped to match `tokenize`: I'll,
        // I'm, I've, I'd, we'll, they're, you're, it's, that's, don't.
        "ill", "im", "ive", "id", "well", "theyre", "youre", "its",
        "thats", "dont", "cant", "wont", "lets",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Capitalized words that are probably names.
    ///
    /// Deliberately ignores the first word of the text and anything after
    /// a full stop — "Tuesday works" should not make "Tuesday" a name on
    /// top of being a day, and "The meeting" should not make "The" one.
    private static func properNouns(in text: String) -> Set<String> {
        // Capitalization plus a stopword list, and deliberately NOT
        // sentence position.
        //
        // The first draft skipped the first word of each sentence, which
        // rejects "The" correctly and "Sarah" wrongly — and names start
        // sentences constantly ("Priya needs 15 units"). One rule, three
        // failing cases. The stopword list already rejects the words that
        // get capitalized for grammatical reasons; position added nothing
        // but the bug.
        //
        // Errs toward calling something a name. A false name costs one
        // fallback — the user gets their exact words — while a missed name
        // means the guard silently stops protecting it, which is the
        // direction that actually hurts.
        var found: Set<String> = []
        for rawWord in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let word = rawWord.trimmingCharacters(
                in: CharacterSet(charactersIn: ",;:()[]\"'.!?"))
            guard let first = word.first, first.isUppercase, word.count > 1,
                  word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" })
            else { continue }
            // Normalized exactly as `tokenize` does, apostrophes and all.
            // They disagreed once: "I'll" was extracted as the name
            // "i'll" and then looked for as "ill", so a faithful rewrite
            // was reported as dropping a name. Two normalizations of one
            // truth is the failure this file's own header warns about.
            let lower = word.lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
            guard !notNames.contains(lower), lower.count > 1 else { continue }
            found.insert(lower)
        }
        return found
    }

    // MARK: - Numbers, including the ones people say out loud

    private static let spokenUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    private static let spokenTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Every number in the text, as digits.
    ///
    /// "Fifteen" and "15" are the same fact and must compare equal — the
    /// model is free to write either, and pinning the *value* rather than
    /// the spelling is what lets it.
    private static func numbers(in words: [String]) -> Set<Int> {
        var found: Set<Int> = []
        var index = 0
        while index < words.count {
            let word = words[index]

            if let digits = Int(word) {
                found.insert(digits)
                index += 1
                continue
            }
            if let unit = spokenUnits[word] {
                found.insert(unit)
                index += 1
                continue
            }
            if let tens = spokenTens[word] {
                // "twenty five" is one number, not two.
                if index + 1 < words.count, let unit = spokenUnits[words[index + 1]], unit < 10 {
                    found.insert(tens + unit)
                    index += 2
                } else {
                    found.insert(tens)
                    index += 1
                }
                continue
            }
            index += 1
        }
        return found
    }
}
