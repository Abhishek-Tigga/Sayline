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
        /// Months are dates, not name-noise. "March deadline" becoming
        /// "April deadline" moves a quarter and used to pass.
        var months: Set<String> = []
        /// "tomorrow", "next week", "this afternoon". A rewrite swapping
        /// this-week for next-week moves a deadline by a week, and every
        /// word of it stays plausible.
        var relativeTimes: Set<String> = []
        /// The unit beside a number. "25 megs" becoming "25 GB" keeps the
        /// number and changes the meaning a thousandfold.
        var units: Set<String> = []
        /// How many negation markers the raw speech carried. A rewrite is
        /// free to rephrase them, not to drop them.
        var negationCount: Int = 0

        var isEmpty: Bool {
            numbers.isEmpty && days.isEmpty && names.isEmpty && months.isEmpty
                && relativeTimes.isEmpty && units.isEmpty && negationCount == 0
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
        case monthLost(String)
        case timeLost(String)
        case unitLost(String)
        /// A negation that was NOT said. Reversing meaning by adding one
        /// is as complete a reversal as dropping one.
        case negationAdded(said: Int, kept: Int)
        /// A person the speaker never named. Worse than a dropped name:
        /// the model put someone in the user's mouth.
        case inventedName(String)
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
            case .monthLost(let m): return "the month \(m.capitalized) was dropped"
            case .timeLost(let t): return "\"\(t)\" was dropped or changed"
            case .unitLost(let u): return "the unit \(u) was changed"
            case .negationAdded:
                return "it added a negation that was never spoken, reversing the meaning"
            case .inventedName(let n):
                return "it named \(n.capitalized), who was never mentioned"
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
            case .monthLost: return "month"
            case .timeLost: return "relative-time"
            case .unitLost: return "unit"
            case .negationAdded: return "negation-added"
            case .inventedName: return "invented-name"
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
        facts.days = Set(words.filter(dayNames.contains))
        facts.months = Set(words.filter(monthNames.contains))
        facts.names = properNouns(in: raw)
        facts.units = Set(words.filter(unitWords.contains))
        facts.relativeTimes = relativeTimes(in: words)
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
        if !facts.months.isEmpty {
            lines.append("months: " + facts.months.sorted().map { $0.capitalized }.joined(separator: ", "))
        }
        if !facts.relativeTimes.isEmpty {
            lines.append("timing: " + facts.relativeTimes.sorted().joined(separator: ", "))
        }
        if !facts.units.isEmpty {
            lines.append("units: " + facts.units.sorted().joined(separator: ", "))
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

        let rewriteMonths = Set(words.filter(monthNames.contains))
        for month in facts.months.sorted() where !rewriteMonths.contains(month) {
            violations.append(.monthLost(month))
        }
        let rewriteUnits = Set(words.filter(unitWords.contains))
        for unit in facts.units.sorted() where !rewriteUnits.contains(unit) {
            violations.append(.unitLost(unit))
        }
        let rewriteTimes = relativeTimes(in: words)
        for time in facts.relativeTimes.sorted() where !rewriteTimes.contains(time) {
            violations.append(.timeLost(time))
        }

        // Counted, not matched, and in BOTH directions. Which words carry
        // the negation is the model's business — "I don't think we should"
        // and "I think we shouldn't" are both faithful. Losing one is not,
        // and neither is inventing one: "I think we should ship" rewritten
        // as "I don't think we should ship" reverses the meaning just as
        // completely, and the first version of this only looked for a
        // decrease.
        //
        // An increase only counts from zero. A faithful rewrite of an
        // already-negative sentence can legitimately add a second negation
        // ("I don't think so, and I don't want to argue"), so full
        // equality would fire constantly.
        let keptNegations = words.filter(negationMarkers.contains).count
        if keptNegations < facts.negationCount {
            violations.append(.negationLost(said: facts.negationCount, kept: keptNegations))
        } else if facts.negationCount == 0 && keptNegations > 0 {
            violations.append(.negationAdded(said: 0, kept: keptNegations))
        }

        // Invention is checked by the `raw:rewrite:` overload, which has
        // the original text. A FactSet has already thrown away the words.
        return violations
    }

    /// Full check including invention, which needs the original text
    /// rather than only the extracted facts.
    static func verify(raw: String, rewrite: String) -> [Violation] {
        var violations = verify(raw: extract(from: raw), rewrite: rewrite)

        // The inverse check, and the more dangerous half. A name the model
        // introduced is a person put in the user's mouth; a dropped name
        // is merely a loss. Compared case-insensitively against the whole
        // raw text, because the raw may well be lowercase — which is
        // exactly the case that leaves dropped names unprotected.
        let rawWords = Set(tokenize(raw))
        for name in properNouns(in: rewrite).sorted() where !rawWords.contains(name) {
            violations.append(.inventedName(name))
        }

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

    private static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Units that change a number's meaning without changing the number.
    private static let unitWords: Set<String> = [
        "percent", "megs", "mb", "gb", "kb", "tb", "rupees", "rupee",
        "dollars", "dollar", "euros", "pounds", "lakh", "lakhs", "crore",
        "crores", "k", "seconds", "minutes", "mins", "hours", "hrs",
        "days", "weeks", "months", "years", "am", "pm",
    ]

    /// Single words and the first word of the two-word phrases below.
    private static let relativeTimeWords: Set<String> = [
        "today", "tomorrow", "tonight", "yesterday", "morning",
        "afternoon", "evening",
    ]

    /// Matched as phrases, because "this" and "next" alone mean nothing
    /// and "next week" versus "this week" is a deadline moved.
    private static let relativeTimePhrases: [[String]] = [
        ["this", "week"], ["next", "week"], ["last", "week"],
        ["this", "month"], ["next", "month"],
        ["this", "morning"], ["this", "afternoon"], ["this", "evening"],
        ["next", "year"], ["this", "quarter"], ["next", "quarter"],
    ]

    private static func relativeTimes(in words: [String]) -> Set<String> {
        var found = Set(words.filter(relativeTimeWords.contains))
        for phrase in relativeTimePhrases {
            for index in words.indices where index + phrase.count <= words.count {
                if Array(words[index..<(index + phrase.count)]) == phrase {
                    found.insert(phrase.joined(separator: " "))
                    // The bigram wins: "this week" is the fact, not "week".
                    found.remove(phrase[1])
                }
            }
        }
        return found
    }

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
        // Semi-negations. real-9's whole argument is "barely anyone
        // clicked it" — losing that word reverses the finding.
        "barely", "hardly", "rarely", "scarcely", "seldom", "without",
    ]

    /// First person singular only, deliberately.
    ///
    /// "we'll" was in this list and would have dominated the fallback
    /// rate: rewrites routinely turn "let's do Monday" into "We'll do
    /// Monday", which is a faithful rendering of a group intention, not a
    /// promise the speaker never made. The cost of flagging it is a
    /// fallback on good output; the safety gain is nil.
    private static let commitmentPhrases: [String] = [
        "i'll", "i will", "i promise", "i guarantee", "i commit",
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
        "thats", "dont", "cant", "wont", "lets", "let",
        // Everything below was found reading ten real dictations, not by
        // imagination: each was being pinned as a *name*, and a false name
        // costs a fallback on a rewrite that was perfectly good.
        "doesnt", "didnt", "isnt", "arent", "wasnt", "werent", "havent",
        "hasnt", "hadnt", "couldnt", "shouldnt", "wouldnt", "youll",
        "youve", "youd", "weve", "wed", "theyll", "theyve", "hes", "shes",
        "can", "could", "should", "would", "will", "yeah", "yes", "sure",
        "maybe", "quick", "update", "about", "for", "from", "with", "our",
        "my", "her", "his", "their", "some", "any", "all", "one", "two",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    private static func tokenize(_ text: String) -> [String] {
        // Thousands separators are removed before splitting. "45,000
        // rupees" used to split on the comma into 45 and 000 — so an
        // invoice amount became two wrong numbers, and the figure that
        // mattered most in the sentence was the one being mangled. Found
        // in real dictation; no invented case had a comma in a number.
        // Possessives go BEFORE apostrophes are stripped, or "Mira's"
        // becomes "miras" here and "mira" in `properNouns` — and a rewrite
        // saying "Mira" then reads as an invented name. This file has now
        // produced that same two-normalizations bug twice; both paths run
        // through `normalizeWords` for exactly that reason.
        normalizeWords(stripThousandsSeparators(text))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .flatMap { splitDigitsFromLetters(String($0)) }
    }

    /// The one normalization. Everything that compares words uses it, so
    /// two callers cannot disagree about what a word is.
    private static func normalizeWords(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'s ", with: " ")
            .replacingOccurrences(of: "'s.", with: ".")
            .replacingOccurrences(of: "'s,", with: ",")
            .replacingOccurrences(of: "'s", with: "s")
            .replacingOccurrences(of: "'", with: "")
    }

    /// Splits a token where digits meet letters: "11ish" -> "11", "ish";
    /// "3pm" -> "3", "pm"; "30th" -> "30", "th".
    ///
    /// "Friday morning like 11ish" is how people say times, and the whole
    /// meeting time was invisible to the guard because the token parsed as
    /// neither a number nor a word. Splitting also gives units for free —
    /// "3pm" now yields both the 3 and the pm.
    private static func splitDigitsFromLetters(_ token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var currentIsDigit: Bool?
        for character in token {
            let isDigit = character.isNumber
            if let was = currentIsDigit, was != isDigit {
                parts.append(current)
                current = ""
            }
            current.append(character)
            currentIsDigit = isDigit
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Turns "45,000" into "45000" so a comma cannot split one number
    /// into two. Only between digits, so ordinary commas are untouched.
    private static func stripThousandsSeparators(_ text: String) -> String {
        var out = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == ",", index > 0, index + 1 < characters.count,
               characters[index - 1].isNumber, characters[index + 1].isNumber {
                continue
            }
            out.append(character)
        }
        return out
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
            // The possessive goes before anything else. "Mira's team"
            // pinned the name as "miras", which no rewrite saying "Mira"
            // could ever satisfy — a guaranteed false positive on a
            // faithful rewrite.
            var word = rawWord.trimmingCharacters(
                in: CharacterSet(charactersIn: ",;:()[]\"'.!?"))
            for possessive in ["'s", "\u{2019}s"] where word.lowercased().hasSuffix(possessive) {
                word = String(word.dropLast(2))
            }
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

    private static let spokenOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]

    /// "30th" -> 30. Nil when the word is not a digit-plus-suffix ordinal.
    private static func ordinalValue(_ word: String) -> Int? {
        guard word.count > 2 else { return nil }
        let suffix = String(word.suffix(2))
        guard ["st", "nd", "rd", "th"].contains(suffix) else { return nil }
        return Int(word.dropLast(2))
    }

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
            // "30th", "1st", "22nd" — a deadline is a number even when it
            // wears a suffix, and "cleared before the 30th" was previously
            // invisible to the guard entirely.
            if let ordinal = ordinalValue(word) {
                found.insert(ordinal)
                index += 1
                continue
            }
            if let unit = spokenUnits[word] ?? spokenOrdinals[word] {
                found.insert(unit)
                index += 1
                continue
            }
            if let tens = spokenTens[word] {
                // "twenty five" is one number, not two.
                // "twenty five" and "twenty first" are both one number.
                if index + 1 < words.count,
                   let unit = spokenUnits[words[index + 1]] ?? spokenOrdinals[words[index + 1]],
                   unit < 10 {
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
