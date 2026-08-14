import Foundation
import NaturalLanguage

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
        /// Real questions the speaker asked. Conversational tics
        /// ("right?", "you know?") are not counted — see `questionCount`.
        var questionCount: Int = 0
        var negationCount: Int = 0

        var isEmpty: Bool {
            numbers.isEmpty && days.isEmpty && names.isEmpty && months.isEmpty
                && relativeTimes.isEmpty && units.isEmpty && negationCount == 0
                && questionCount == 0
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
        /// A quantifiable that appears in the rewrite and nowhere in the
        /// speech. The mirror of the survival checks, and the half that
        /// caught a model appending "there are 2 potential issues".
        case inventedNumber(Int)
        case inventedDay(String)
        case inventedMonth(String)
        case inventedUnit(String)
        /// The rewrite is longer than the speech.
        ///
        /// Voice 2, rule 5a. Work mode compresses toward the speaker's own
        /// words; a rewrite that grows has added something, and the thing
        /// it adds is almost always padding. This one check would have
        /// killed the invented meta-sentence of B2 with no prompt change
        /// at all.
        case longerThanSpeech(said: Int, wrote: Int)
        /// A formality the speaker did not use.
        ///
        /// Voice 2, rules 2 and 3. "isn't done" must not become "remains
        /// incomplete", and "I don't agree" must never become "I'm not
        /// fully aligned" — softening a stated position is meaning change
        /// wearing a politeness costume, which is the same family as the
        /// corruption this guard exists for.
        case formalityUpgrade(String)
        /// The speaker asked something and the rewrite answers it instead.
        ///
        /// Both observed qualitative inventions had this shape: a
        /// rhetorical question turned into a self-contradictory claim
        /// ("Doesn't that work for you?" → "Friday morning at 11 won't
        /// work if you have a conflict, but it's an option"). The invented
        /// sentence carries no number or date, so the subset rule cannot
        /// see it — but "a question went in and none came out" is
        /// mechanical.
        case questionLost(asked: Int)
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
            case .longerThanSpeech(let said, let wrote):
                return "the rewrite is longer than what was said (\(said) words in, \(wrote) out) — cut, don't pad"
            case .formalityUpgrade(let phrase):
                return "it used \"\(phrase)\", which the speaker did not say — keep their words"
            case .questionLost:
                return "the speaker asked a question and the rewrite answered it instead"
            case .inventedNumber(let n): return "it introduced the number \(n), which was never said"
            case .inventedDay(let d): return "it introduced \(d.capitalized), which was never said"
            case .inventedMonth(let m): return "it introduced \(m.capitalized), which was never said"
            case .inventedUnit(let u): return "it introduced the unit \(u), which was never said"
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
            case .longerThanSpeech(let said, let wrote):
                return "the rewrite is longer than what was said (\(said) words in, \(wrote) out) — cut, don't pad"
            case .formalityUpgrade(let phrase):
                return "it used \"\(phrase)\", which the speaker did not say — keep their words"
            case .longerThanSpeech: return "longer-than-speech"
            case .formalityUpgrade: return "formality-upgrade"
            case .questionLost: return "question-lost"
            case .inventedNumber: return "invented-number"
            case .inventedDay: return "invented-day"
            case .inventedMonth: return "invented-month"
            case .inventedUnit: return "invented-unit"
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
        facts.units = units(in: raw, words: words)
        facts.relativeTimes = relativeTimes(in: words)
        facts.negationCount = countNegations(in: words)
        facts.questionCount = countQuestions(in: raw)
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

    /// Words an email shell may add: "Hi <name>," and "Best,\n<name>".
    ///
    /// Twelve is deliberately generous — the shell is four to six words,
    /// and a ceiling that a compliant email can graze is a ceiling that
    /// will refuse good rewrites for the sake of arithmetic.
    static let emailShellAllowance = 12

    static func verify(raw facts: FactSet, rewrite: String,
                       context: AppContext = .general) -> [Violation] {
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
        let rewriteUnits = units(in: rewrite, words: words)
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
        //
        // Narrowed after the model bake-off: losing *some* negation is
        // allowed, losing *all* of it is not. Work mode is supposed to
        // delete thinking-out-loud, and a dropped rhetorical question
        // ("Doesn't that work for you?") takes its negation with it. The
        // strict version fired on correct rewrites and was 8 of 13
        // violations across every model — the guard fighting the mode it
        // protects. Going to zero is still the meaning-reversal case.
        let keptNegations = countNegations(in: words)
        if facts.negationCount > 0 && keptNegations == 0 {
            violations.append(.negationLost(said: facts.negationCount, kept: keptNegations))
        } else if facts.negationCount == 0 && keptNegations > 0 {
            violations.append(.negationAdded(said: 0, kept: keptNegations))
        }

        // All-or-nothing, exactly as negations had to become. Merging two
        // questions into one is faithful; answering them all is not.
        if facts.questionCount > 0 && !rewrite.contains("?") {
            violations.append(.questionLost(asked: facts.questionCount))
        }

        // Invention is checked by the `raw:rewrite:` overload, which has
        // the original text. A FactSet has already thrown away the words.
        return violations
    }

    /// Full check including invention, which needs the original text
    /// rather than only the extracted facts.
    static func verify(raw: String, rewrite: String,
                       context: AppContext = .general) -> [Violation] {
        var violations = verify(raw: extract(from: raw), rewrite: rewrite, context: context)

        // The inverse check, and the more dangerous half. A name the model
        // introduced is a person put in the user's mouth; a dropped name
        // is merely a loss. Compared case-insensitively against the whole
        // raw text, because the raw may well be lowercase — which is
        // exactly the case that leaves dropped names unprotected.
        let rawWords = Set(tokenize(raw))
        for name in properNouns(in: rewrite).sorted() where !rawWords.contains(name) {
            violations.append(.inventedName(name))
        }

        // The subset rule: nothing quantifiable may appear that was not
        // said. The mirror of the survival checks above, and the half that
        // was missing — a model appended "there are 2 potential issues
        // with the new time" to a faithful rewrite and the guard called it
        // clean, because it only ever asked whether the user's facts
        // survived, never whether new ones had arrived.
        //
        // Deliberately limited to quantifiables. Deciding "substantive
        // claim" against "connective tissue" is semantics, and word lists
        // cannot do it — see `sentenceNovelty` for the bounded, measured
        // attempt at the rest.
        let rawFacts = extract(from: raw)
        let newFacts = extract(from: rewrite)
        for number in newFacts.numbers.subtracting(rawFacts.numbers).sorted()
        where number != 0 {   // a bare 0 is punctuation of a time, never a claim
            violations.append(.inventedNumber(number))
        }
        for day in newFacts.days.subtracting(rawFacts.days).sorted() {
            violations.append(.inventedDay(day))
        }
        for month in newFacts.months.subtracting(rawFacts.months).sorted() {
            violations.append(.inventedMonth(month))
        }
        for unit in newFacts.units.subtracting(rawFacts.units).sorted() {
            violations.append(.inventedUnit(unit))
        }

        // Voice 2, rule 5a — the length ceiling. Reworked 2026-08-14.
        //
        // **Was:** strictly shorter above nine words. **Now:** never
        // longer, at any length, plus an allowance for an email shell.
        //
        // Two pieces of live evidence killed the old rule. Taste round 1:
        // the rewrite deleted the opener in roughly half of eighteen cases
        // — "quick status on X", "heads up", "hi Nikhil" — and the leading
        // theory is that a strictly-shorter budget teaches the model to
        // make room by chopping the head. And in S2 the guard refused a
        // corrective RETRY for "26 words in, 26 out": an equal-length,
        // possibly-good rescue thrown away because the rule demanded one
        // word fewer. Equal length is not padding.
        //
        // The email allowance exists because the approved email shell —
        // greeting plus "Best, [name]" — ADDS words by design. Without it
        // every compliant email would violate the ceiling, and the
        // decapitation this change exists to stop would come back wearing
        // a different hat.
        let spokenWords = tokenize(raw).count
        let writtenWords = tokenize(rewrite).count
        let ceiling = spokenWords + (context == .email ? emailShellAllowance : 0)
        if writtenWords > ceiling {
            violations.append(.longerThanSpeech(said: spokenWords, wrote: writtenWords))
        }

        let rawLower = raw.lowercased()
        let rewriteLower = rewrite.lowercased()

        // Voice 2, rules 2 and 3 — formality the speaker did not use.
        //
        // Only when absent from the raw: a guard that forbids the user's
        // own vocabulary is worse than no guard. "As per the contract"
        // stays if they said it.
        for phrase in formalityUpgrades where rewriteLower.contains(phrase)
            && !rawLower.contains(phrase) {
            violations.append(.formalityUpgrade(phrase))
        }
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

    // MARK: - The bounded attempt at qualitative invention

    /// How much of each rewrite sentence appeared in the speech.
    ///
    /// The subset rule catches an invented *number*. It cannot catch "The
    /// api is affected by these issues" — deciding a substantive claim
    /// from connective tissue is semantics, and word lists do not do
    /// semantics. This is the bounded attempt: a sentence whose content
    /// words are mostly absent from the raw is a candidate invention.
    ///
    /// Returns the novelty fraction per sentence (1.0 = nothing in it was
    /// said). **Deliberately not wired into `verify`** until the numbers
    /// justify a threshold — the expected false positive is a faithful
    /// compression that uses synonyms ("60% done" → "more than half
    /// complete"), and shipping this unmeasured would trade a real
    /// invention for a pile of thrown-away good rewrites.
    static func sentenceNovelty(raw: String, rewrite: String) -> [(sentence: String, novelty: Double)] {
        let spoken = Set(tokenize(raw)).subtracting(noveltyStopwords)
        var out: [(String, Double)] = []
        for sentence in rewrite.split(whereSeparator: { ".!?\n".contains($0) }) {
            let content = tokenize(String(sentence)).filter { !noveltyStopwords.contains($0) }
            guard content.count >= 3 else { continue }   // too short to judge
            let unseen = content.filter { !spoken.contains($0) }.count
            out.append((sentence.trimmingCharacters(in: .whitespaces),
                        Double(unseen) / Double(content.count)))
        }
        return out
    }

    /// Words too common to signal anything about novelty.
    private static let noveltyStopwords: Set<String> = grammarWords
        .union(modals)
        .union(discourseWords)
        .union(["to", "of", "in", "on", "at", "by", "be", "been", "as",
                "not", "no", "or", "up", "out", "we", "us", "them"])

    // MARK: - Pieces

    private static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Units found as words or as symbols.
    ///
    /// `tokenize` drops "%" and "₹" as separators, so a faithful rewrite
    /// of "60 percent" as "60%" read as a *lost* unit — and models write
    /// symbols for money and percentages almost always, so this fired on
    /// exactly the sentences the guard most exists to protect. Confirmed
    /// live by Fable, 2026-08-13.
    ///
    /// The mapping is within a currency, never across one: "rupees"
    /// rewritten as "$" must still raise both a lost rupee and an
    /// invented dollar.
    private static func units(in text: String, words: [String]) -> Set<String> {
        // A unit counts only when it sits beside a number.
        //
        // Fable's rule was "pin the unit token adjacent to each number";
        // this was implemented as bare set membership, which pinned
        // "second" in "second the timeline" as the time unit *seconds* —
        // so turning a dictated list into bullets dropped it and the guard
        // fell back on exactly the output the user had asked for. A unit
        // with no quantity beside it is an ordinary word.
        var found: Set<String> = []
        for (index, word) in words.enumerated() where unitWords.contains(word) {
            let before = index > 0 ? words[index - 1] : ""
            let after = index + 1 < words.count ? words[index + 1] : ""
            let isQuantified = [before, after].contains { token in
                Int(token) != nil || spokenUnits[token] != nil
                    || spokenTens[token] != nil || quantityWords[token] != nil
            }
            if isQuantified { found.insert(word) }
        }
        for (symbol, canonical) in unitSymbols where text.contains(symbol) {
            found.insert(canonical)
        }
        // "rupee" and "rupees" are one unit; compare on the canonical form
        // so a singular/plural shift is not a violation either.
        return Set(found.map { unitSynonyms[$0] ?? $0 })
    }

    private static let unitSymbols: [String: String] = [
        "%": "percent", "₹": "rupees", "$": "dollars", "£": "pounds", "€": "euros",
    ]

    private static let unitSynonyms: [String: String] = [
        "rupee": "rupees", "dollar": "dollars", "euro": "euros", "pound": "pounds",
        "min": "minutes", "mins": "minutes", "minute": "minutes",
        "hr": "hours", "hrs": "hours", "hour": "hours",
        "second": "seconds", "day": "days", "week": "weeks",
        "month": "months", "year": "years", "meg": "megs", "mb": "megs",
    ]

    /// Units that change a number's meaning without changing the number.
    private static let unitWords: Set<String> = [
        "percent", "megs", "mb", "gb", "kb", "tb", "rupees", "rupee",
        "dollars", "dollar", "euros", "pounds", "lakh", "lakhs", "crore",
        "crores", "k", "seconds", "minutes", "mins", "hours", "hrs",
        "days", "weeks", "months", "years", "am", "pm",
        // Singulars, so "one week" and "one hour" pin their number. The
        // pronoun rule consults this lexicon, and it held only plurals.
        "second", "minute", "min", "hour", "hr", "day", "week", "month",
        "year", "percent", "meg", "gig",
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

    /// Words that make a sentence sound more important without making it
    /// mean more.
    ///
    /// **Growth rule, same as the stopword list:** every entry arrives
    /// with the real rewrite that motivated it, as a suite case, in the
    /// same commit. No entries added by imagining what a model might say.
    ///
    /// The first eight are the classic inflations named in the Voice 2
    /// decision. The last two were produced by this user's own live
    /// session on 2026-08-13 — "let's do Thursday" came back as "We will
    /// do it on Thursday", and "we don't think" as "We do not think".
    /// Expanding a contraction changes nothing but the temperature, which
    /// is exactly what rule 2 forbids.
    private static let formalityUpgrades: [String] = [
        "utilize", "leverage", "i would like to propose", "at this stage",
        "not fully aligned", "i have some reservations", "as per", "kindly",
        "let us", "do not",
    ]

    /// First person singular only, deliberately.
    ///
    /// "we'll" was in this list and would have dominated the fallback
    /// rate: rewrites routinely turn "let's do Monday" into "We'll do
    /// Monday", which is a faithful rendering of a group intention, not a
    /// promise the speaker never made. The cost of flagging it is a
    /// fallback on good output; the safety gain is nil.
    /// Negations, minus the ones a conditional brought with it.
    ///
    /// "or it slips to the next month cycle" rewritten as "**if** it is
    /// **not** cleared by then, it will slip" is the same sentence; the
    /// negation belongs to the conditional, not to a reversal of meaning.
    /// That fired once falsely in the first bake-off and never truly, so
    /// the exclusion gives up almost nothing.
    ///
    /// The case the rule exists for — a bare assertion reversed, "we
    /// should ship" becoming "we shouldn't ship" — is essentially never
    /// phrased conditionally.
    /// Questions worth protecting.
    ///
    /// A sentence ending in "?" that is not a conversational tic. "we
    /// should ship, right?" is a statement wearing a question mark, and
    /// pinning it would fire on every faithful rewrite of ordinary
    /// speech.
    private static func countQuestions(in text: String) -> Int {
        // Only segments actually terminated by "?" count. The first
        // version split on "?" and counted every piece, so a statement
        // with no question mark at all yielded one question and every
        // faithful rewrite of ordinary speech was flagged.
        var count = 0
        var current = ""
        for character in text {
            if character == "?" {
                if isRealQuestion(current) { count += 1 }
                current = ""
            } else if character == "." || character == "!" || character == "\n" {
                current = ""
            } else {
                current.append(character)
            }
        }
        return count
    }

    /// A sentence ending in "?" that is not a conversational tic. "we
    /// should ship, right?" is a statement wearing a question mark, and
    /// pinning it would fire on every faithful rewrite of ordinary speech.
    private static func isRealQuestion(_ sentence: String) -> Bool {
        let words = tokenize(sentence)
        guard let last = words.last else { return false }
        guard questionTics.contains(last) else { return true }
        // A tic ending it only disqualifies when the sentence did not
        // *open* interrogatively. Position matters: English inverts for
        // questions, so "Doesn't that work for you?" is one and "we
        // should ship, right?" is not — even though both contain a modal.
        // Checking anywhere in the sentence made every "we should…" a
        // question.
        return words.first.map(interrogatives.contains) == true
    }

    private static let questionTics: Set<String> = [
        "right", "yeah", "ok", "okay", "no", "yes", "know", "mean", "see",
    ]

    private static let interrogatives: Set<String> = [
        "what", "when", "where", "who", "why", "how", "which", "can",
        "could", "should", "would", "will", "do", "does", "did", "is",
        "are", "was", "were", "shall", "may", "doesnt", "dont", "isnt",
    ]

    private static func countNegations(in words: [String]) -> Int {
        var count = 0
        for (index, word) in words.enumerated() where negationMarkers.contains(word) {
            let window = words[max(0, index - 3)..<index]
            if window.contains(where: conditionalMarkers.contains) { continue }
            count += 1
        }
        return count
    }

    private static let conditionalMarkers: Set<String> = [
        "if", "unless", "whether", "until", "otherwise", "in case",
    ]

    private static let commitmentPhrases: [String] = [
        "i'll", "i will", "i promise", "i guarantee", "i commit",
    ]

    private static let commitmentEquivalents: [String: [String]] = [
        "i'll": ["i will", "i shall"],
        "i will": ["i'll", "i shall"],
        "we'll": ["we will"],
        "we will": ["we'll"],
    ]

    /// Words that get capitalized for grammatical reasons rather than
    /// because they name something.
    ///
    /// **This list is load-bearing and it grows. The rule for growing it:**
    /// every addition arrives with the real transcript that motivated it,
    /// added to `eval/factguard-checks` as a case in the same commit. No
    /// entries added by imagining what might appear — that is how the list
    /// rots into someone's guess about English. Production is the other
    /// source: a `name` violation in the fallback log is a candidate,
    /// because it means a real rewrite was thrown away over a word that is
    /// not a name.
    ///
    /// Grouped so a reader can see why each class exists. Calendar words
    /// are deliberately **absent** — months and days are pinned facts in
    /// their own right, not noise to be filtered.
    private static let notNames: Set<String> = grammarWords
        .union(contractions)
        .union(modals)
        .union(discourseWords)
        .union(imperativeVerbs)
        .union(genericPlaceNouns)

    /// Verbs that open a dictated sentence and get capitalized for it.
    ///
    /// The belt behind `NLTagger`. Measured 2026-08-14: the tagger tags
    /// "Tell" in "Tell Rohit the deploy is done" as a personal name and
    /// does NOT tag it as a verb, so the lexical-class check misses it.
    /// The tagger is right that a name is nearby and wrong about which
    /// word; this list settles the argument for the words people actually
    /// start dictating with.
    private static let imperativeVerbs: Set<String> = [
        "tell", "ask", "make", "see", "push", "send", "check", "keep",
        "give", "take", "move", "call", "email", "ping", "remind", "note",
        "add", "remove", "update", "fix", "ship", "try", "use", "get",
        "put", "run", "look", "think", "know", "say", "said", "want",
        "need", "start", "stop", "hold", "wait", "follow", "review",
        "share", "draft", "write", "read", "book", "schedule", "cancel",
    ]

    /// Common nouns that follow a real name in a place or building name.
    ///
    /// "Sterling Essentia Apartment" pins the first two words correctly
    /// and would pin the third from its mid-sentence capital. A rewrite
    /// saying "the Sterling Essentia" is faithful, so pinning "apartment"
    /// buys a false violation and nothing else.
    private static let genericPlaceNouns: Set<String> = [
        "apartment", "apartments", "building", "tower", "towers", "house",
        "street", "road", "avenue", "lane", "block", "office", "room",
        "floor", "campus", "park", "plaza", "centre", "center",
    ]

    /// Articles, pronouns, prepositions, conjunctions — the words that
    /// open sentences and mean nothing on their own.
    private static let grammarWords: Set<String> = [
        "i", "the", "a", "an", "and", "but", "so", "then", "this", "that",
        "these", "those", "it", "we", "they", "he", "she", "you", "if",
        "when", "what", "why", "how", "where", "who", "there", "here",
        "for", "from", "with", "our", "my", "her", "his", "their", "some",
        "any", "all", "one", "two", "about", "let", "lets",
    ]

    /// Apostrophe-stripped, to match `normalizeWords`. Found by reading
    /// real dictation: "Doesn't that work for you?" was pinning a name.
    private static let contractions: Set<String> = [
        "ill", "im", "ive", "id", "well", "theyre", "youre", "its",
        "thats", "dont", "cant", "wont", "doesnt", "didnt", "isnt",
        "arent", "wasnt", "werent", "havent", "hasnt", "hadnt", "couldnt",
        "shouldnt", "wouldnt", "youll", "youve", "youd", "weve", "wed",
        "theyll", "theyve", "hes", "shes",
    ]

    /// Verbs that open a question or a request, which is how half of a
    /// dictated message begins: "Can we do the demo on Thursday?"
    private static let modals: Set<String> = [
        "can", "could", "should", "would", "will", "shall", "may",
        "might", "must", "do", "does", "did", "is", "are", "was", "were",
        "have", "has", "had", "need", "needs",
    ]

    /// The words people actually start spoken sentences with. Every one
    /// of these was pinned as a name by a real transcript.
    private static let discourseWords: Set<String> = [
        "yes", "no", "ok", "okay", "yeah", "sure", "maybe", "please",
        "thanks", "hi", "hey", "hello", "also", "just", "actually",
        "basically", "quick", "update", "honestly", "anyway", "right",
        "look", "listen", "sorry", "great",
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
            // A time separator splits rather than fuses: "11:00" must not
            // become the number 1100, which is what removing the colon
            // produced. It yields 11 and 0, and 0 is excluded from the
            // invention rule precisely so a written time cannot look like
            // a new fact.
            .replacingOccurrences(of: ":", with: " ")
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

    /// Words that are actually names, per Apple's on-device tagger.
    ///
    /// **This replaces a capitalization heuristic that live data
    /// convicted.** The old rule took any capitalized word not on a
    /// stopword list. Dictation capitalizes the start of every sentence,
    /// so on 2026-08-14 the guard pinned "See", "Make", "First", "After",
    /// "Whether" and — in "Sterling Essentia Apartment" — "Apartment" as
    /// people. Each phantom forced a corrective retry, a second full API
    /// round trip. Names were the largest single driver of a ~50% retry
    /// rate and roughly doubled work mode's latency.
    ///
    /// The old comment argued a false name was cheap: "costs one fallback
    /// — the user gets their exact words". Measurement disagreed. It cost
    /// a round trip on more than half of all work dictations.
    ///
    /// **A deliberate bend in this file's stated virtue.** FactGuard's
    /// value has been that it is dumb, deterministic code rather than a
    /// second model. `NLTagger` is not dumb code — it is a trained
    /// on-device tagger. It is still deterministic for a given input, runs
    /// in milliseconds, needs no network, and cannot invent text. The
    /// trade was made because a capitalization rule cannot tell "Make use
    /// of this" from "Priya needs 15 units", and pretending otherwise cost
    /// the user latency on every second dictation. Flagged rather than
    /// slipped in.
    ///
    /// The stopword list stays as a belt: the tagger occasionally marks a
    /// sentence-initial verb as a personal name, and `notNames` catches
    /// what it should never have been. Ordinals join it unconditionally —
    /// they were evicted from number-pinning and landed here instead,
    /// which is whack-a-mole rather than a fix.
    private static func properNouns(in text: String) -> Set<String> {
        var found: Set<String> = []
        let full = text.startIndex..<text.endIndex
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        // Signal 1 — the tagger, minus anything it also calls a verb.
        //
        // Measured 2026-08-14: the tagger tags "Tell" in "Tell Rohit the
        // deploy is done" as a personal name. It is right that a name is
        // near there and wrong about which word. Checking the lexical
        // class separates the two cases the old heuristic could not:
        // "Tell" is a verb at a sentence start, "Priya" in "Priya needs 15
        // units" is not.
        let names = NLTagger(tagSchemes: [.nameType])
        names.string = text
        let classes = NLTagger(tagSchemes: [.lexicalClass])
        classes.string = text
        names.enumerateTags(in: full, unit: .word, scheme: .nameType, options: options) { tag, range in
            guard let tag, tag == .personalName || tag == .placeName
                    || tag == .organizationName else { return true }
            let lexical = classes.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
            guard lexical != .verb else { return true }
            // A joined name arrives as one range ("Sterling Essentia"), so
            // each word is pinned separately — a rewrite may keep the
            // person and drop the company, and that is still a loss.
            for word in text[range].split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }) {
                found.formUnion(normalizedName(String(word)))
            }
            return true
        }

        // Signal 2 — capitalized words that are NOT starting a sentence.
        //
        // The tagger misses real names with dull context: "Priya" in "Ask
        // Nikhil and Priya" and "Essentia" in "the Sterling Essentia
        // lease" were both dropped, while their neighbours were caught. A
        // capital mid-sentence is a strong signal and, crucially, is the
        // one place the old heuristic was never wrong — dictation
        // capitalizes sentence STARTS, which is what produced "See",
        // "Make" and "First". Restricting the rule to mid-sentence keeps
        // its power and removes its failure mode.
        //
        // A missed name is the worse direction: the guard silently stops
        // protecting it. A phantom costs a round trip, which is what this
        // whole change is repaying.
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            let words = sentence.split(whereSeparator: { $0 == " " || $0 == "\t" })
            for word in words.dropFirst() where word.first?.isUppercase == true {
                found.formUnion(normalizedName(String(word)))
            }
        }
        return found
    }

    /// Trims, strips the possessive, normalizes apostrophes, and applies
    /// the exclusions. Returns empty when the word is not a name after
    /// all.
    ///
    /// Normalized exactly as `tokenize` does, apostrophes and all. They
    /// disagreed once: "I'll" was extracted as the name "i'll" and then
    /// looked for as "ill", so a faithful rewrite was reported as dropping
    /// a name. Two normalizations of one truth is the failure this file's
    /// own header warns about.
    private static func normalizedName(_ raw: String) -> Set<String> {
        var word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]\"'.!?"))
        for possessive in ["'s", "\u{2019}s"] where word.lowercased().hasSuffix(possessive) {
            word = String(word.dropLast(2))
        }
        guard word.count > 1,
              word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" })
        else { return [] }
        let lower = word.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        // Calendar words are pinned in their own classes, so they must not
        // *also* be names — a dropped Friday should report one violation,
        // not two.
        guard !dayNames.contains(lower), !monthNames.contains(lower),
              !notNames.contains(lower), !ordinalWords.contains(lower),
              lower.count > 1
        else { return [] }
        return [lower]
    }

    /// Ordinals are never names. They were evicted from number-pinning
    /// after "first/second/third" were pinned as numbers, and landed in
    /// name-pinning instead — the same bug wearing a different hat.
    private static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth", "eleventh", "twelfth", "last", "next",
        "final", "former", "latter",
    ]

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

    /// Words that carry a quantity without being numbers.
    ///
    /// Without these the subset rule storms: a faithful rewrite of "both
    /// options" as "2 options" would report an invented 2. Mapped on both
    /// sides, so the two spellings of one quantity compare equal — the
    /// same reason "fifteen" and 15 do.
    private static let quantityWords: [String: Int] = [
        "both": 2, "pair": 2, "couple": 2, "dozen": 12, "twice": 2,
        "half": 1, "single": 1, "once": 1, "thrice": 3,
    ]

    /// Ordinals small enough to be list markers in ordinary speech.
    private static let enumerationMarkers: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth",
        "seventh", "eighth", "ninth", "tenth",
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
            // "one" is usually prose, not a quantity. "quick one", "the
            // last one", "no one", "one more thing" — all pinned the
            // number 1 and then reported it lost when a faithful rewrite
            // dropped the phrase. It counts only when a unit follows.
            //
            // The apparent hole this leaves — "one bug" rewritten as "two
            // bugs" — is closed from the other side: the subset rule flags
            // the invented 2. Compound spoken numbers reach the tens+units
            // path above and never consult this.
            if word == "one" {
                let next = index + 1 < words.count ? words[index + 1] : ""
                if unitWords.contains(next) { found.insert(1) }
                index += 1
                continue
            }
            if let quantity = quantityWords[word] {
                found.insert(quantity)
                index += 1
                continue
            }
            // A bare small ordinal is an enumeration marker, not a fact.
            //
            // "three reasons: first the cost, second the timeline" pinned
            // 1 and 2, so turning that into the bullet list the user asked
            // for dropped them and the guard fell back — on exactly the
            // output that was wanted. The prompt was fighting the guard.
            //
            // Digit ordinals ("the 30th") and compounds ("twenty first")
            // stay facts, because that is how a real date is spoken. The
            // cost is "the first of March" losing its 1; March is still
            // pinned, so the date is not wholly unprotected.
            if enumerationMarkers.contains(word) {
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
