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
        case inventedTime(String)
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
            case .inventedTime(let t): return "it introduced \"\(t)\", which was never said"
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
            case .longerThanSpeech: return "longer-than-speech"
            case .formalityUpgrade: return "formality-upgrade"
            case .questionLost: return "question-lost"
            case .inventedNumber: return "invented-number"
            case .inventedDay: return "invented-day"
            case .inventedTime: return "invented-relative-time"
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

    /// Words a rewrite may add to close the ellipsis in speech.
    ///
    /// Dictation drops the words writing needs — "feels like a lot of
    /// meetings" becomes "It feels like a lot of meetings", and that "It"
    /// was a guard violation until Fable's ruling of 2026-08-14. Applies
    /// in every context, and adds to `emailShellAllowance` rather than
    /// replacing it.
    ///
    /// Two words is grammar. Three is padding. See the ruling in
    /// `review/LEDGER.md` for why this is a constant and not a
    /// percentage.
    ///
    /// **Held at 2 deliberately, not tuned to it.** The evidence cannot
    /// distinguish 2 from 3 — the violations sit at +1, +3 and +5 and
    /// nothing observed sits at +3 or +4. Fable's ruling: when evidence is
    /// indifferent the tighter value wins by default, because the recorded
    /// drift this week was six relaxations and no tightenings. It moves
    /// only if a taste round produces length complaints, in either
    /// direction.
    static let grammarTolerance = 2

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
        // Waiver 1 (Fable, 2026-08-14): `timeLost` is DELETED as a class.
        //
        // It was added for the real-6 week-swap danger, but a presence
        // check never protected against a swap — the raw contains both
        // weeks, so any rewrite passes the subset test. All it ever caught
        // was *deletions*, and the deletions it caught were "all morning"
        // and "going back and forth" — the journey the prompt explicitly
        // orders removed. The class was mis-specified, not mis-implemented:
        // the guard was reporting the prompt doing its job.
        //
        // The invention side stays, in the `raw:rewrite:` overload. A
        // relative time APPEARING that was never spoken is still a
        // violation — that direction was never the problem.

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

    // MARK: - Retraction waivers
    //
    // Fable's decision, 2026-08-14, after self-correction became the
    // dominant false positive: **tolerance, not deletion.** The model
    // already decides what to write; these waivers only stop the guard
    // punishing a decision the speaker made out loud.
    //
    // That framing is what keeps this away from PRODUCT.md's rejected
    // "delete the self-correction" idea, which was adjacent to the
    // data-loss bug. Nothing here removes text. A waiver being wrong means
    // a violation is not raised — and it is only ever consulted when the
    // model already dropped the value, because a good rewrite keeps real
    // facts anyway.

    /// Phrases that mark the speaker taking something back.
    ///
    /// **Phrases, not words — this was a bug before it was a design.** The
    /// first version listed bare words including "wait", "no", "make" and
    /// "mean". In "Priya and Arjun are both out so the release has to
    /// WAIT unless Meera can cover it", the ordinary verb "wait" was read
    /// as a retraction and silently waived two dropped names. That is the
    /// failure direction Fable's decision warned about: a false retraction
    /// loses protection with no violation and no fallback to notice.
    ///
    /// Each single word left here is one that essentially only appears
    /// when someone is correcting themselves. Everything ambiguous — wait,
    /// no, make, mean — now needs its partner, which is how people
    /// actually say it: "no wait", "hold on", "I mean", "make that".
    private static let retractionPhrases: [[String]] = [
        ["actually"], ["instead"], ["sorry"],
        ["no", "wait"], ["wait", "no"], ["hold", "on"],
        ["scratch", "that"], ["i", "mean"], ["make", "that"],
    ]

    /// Indices in `words` where a retraction phrase begins.
    private static func retractionMarkerIndices(in words: [String]) -> Set<Int> {
        var found: Set<Int> = []
        for start in words.indices {
            for phrase in retractionPhrases where start + phrase.count <= words.count {
                if Array(words[start..<(start + phrase.count)]) == phrase {
                    found.insert(start)
                }
            }
        }
        return found
    }

    /// Raw-token indices Clean may drop because the speaker corrected
    /// themselves, or empty when no retraction is present.
    ///
    /// **The same gate as the waivers below, deliberately shared.** A
    /// phrase marker, and a same-class value after it that survived into
    /// the cleaned text. Clean asked for retraction handling and the
    /// obvious move was a second detector in the cleanup layer; two
    /// implementations of "did they take it back" would drift, and the
    /// one in this file is the one with the boundary cases already in a
    /// suite.
    ///
    /// The span is three things and nothing else:
    ///   1. the retracted value, whole — a number phrase is "forty
    ///      thousand", not "forty"
    ///   2. the marker itself
    ///   3. the tokens between the marker and the surviving successor —
    ///      the reason zone, which is where "Tuesday I am busy" lives
    ///
    /// Deliberately NOT the tokens between the retracted value and the
    /// marker: in C3 that region is "to review it", which the corrected
    /// sentence still needs. C1's reason sits after the marker and C3's
    /// sits after the successor, which is exactly why one is droppable
    /// and the other is not — the shape of the sentence, not a judgement.
    ///
    /// Whether a droppable reason SHOULD be dropped is the model's call,
    /// on two prompt lines. This only decides what the validator will
    /// permit. See `review/LEDGER.md`, C-group intensity.
    static func retractionDropSpan(raw: String, cleaned: String) -> Set<Int> {
        let words = tokenize(raw)
        let markers = retractionMarkerIndices(in: words)
        guard !markers.isEmpty else { return [] }

        let survived = Set(tokenize(cleaned))
        let rawNames = properNouns(in: raw)
        let dayPositions = words.indices.filter { dayNames.contains(words[$0]) }
        let namePositions = words.indices.filter { rawNames.contains(words[$0]) }
        let numberPositions = words.indices.filter { numberPhrase(in: words, at: $0) != nil }

        var span: Set<Int> = []
        for marker in markers {
            let length = retractionPhrases
                .filter { marker + $0.count <= words.count
                          && Array(words[marker..<(marker + $0.count)]) == $0 }
                .map(\.count).max() ?? 1
            let markerEnd = marker + length

            for positions in [dayPositions, namePositions, numberPositions] {
                guard let retracted = positions.last(where: { $0 < marker }),
                      let successor = positions.first(where: {
                          $0 >= markerEnd && survived.contains(words[$0])
                      })
                else { continue }

                // The retracted value, whole.
                var end = retracted + 1
                if let (_, next) = numberPhrase(in: words, at: retracted) { end = next }
                span.formUnion(retracted..<end)
                // The marker.
                span.formUnion(marker..<markerEnd)
                // The reason zone, between marker and successor.
                if markerEnd < successor { span.formUnion(markerEnd..<successor) }
                // The successor's own slot is deliberately NOT added
                // here. A corrected sentence often moves the replacement
                // to where the retracted value stood, which reads to a
                // positional diff as a deletion — but "the word moved"
                // and "the word is needed twice" look identical from
                // inside this function. Adding it put a second "forty"
                // in C2's budget and the diff spent it on the real
                // number, turning 45,000 into 5,000. The validator
                // decides relocation instead, where the counts are.
            }
        }
        return span
    }

    /// The droppable span as words, for callers that tokenize differently.
    ///
    /// `TranscriptCleanupValidator` splits on whitespace and keeps
    /// punctuation on the token; this file strips punctuation and splits
    /// digits from letters. Handing the validator raw indices from here
    /// would line up until the first "9:30" and then silently point at the
    /// wrong word, so it gets words and consumes them as a multiset —
    /// which also bounds over-deletion to exactly the count the span
    /// permits.
    static func retractionDroppableWords(raw: String, cleaned: String) -> [String] {
        let words = tokenize(raw)
        return retractionDropSpan(raw: raw, cleaned: cleaned)
            .sorted()
            .filter { $0 < words.count }
            .map { words[$0] }
    }

    /// Drops violations the speaker's own correction explains.
    ///
    /// Works on positions, which is why it lives here rather than in the
    /// `FactSet` overload — a FactSet has thrown the word order away, and
    /// "was there a marker BETWEEN these two values" is the whole rule.
    private static func withoutRetractions(_ violations: [Violation],
                                           raw: String, rewrite: String) -> [Violation] {
        let rawWords = tokenize(raw)
        let rewriteWords = tokenize(rewrite)
        let rewriteSet = Set(rewriteWords)
        let rewriteNumbers = numbers(in: rewriteWords)
        let rawNames = properNouns(in: raw)
        let markers = retractionMarkerIndices(in: rawWords)

        /// A marker sits strictly between two positions.
        func markerBetween(_ a: Int, _ b: Int) -> Bool {
            markers.contains { $0 > a && $0 < b }
        }

        /// Waiver 2, in one shape for every class: the dropped value
        /// appears at some position, a same-class value that SURVIVED
        /// appears later, and a retraction marker sits between them.
        ///
        /// The between-ness is what keeps the both-real case safe. "Move
        /// Tuesday's meeting to Thursday" has no marker between the days,
        /// so a dropped Tuesday still flags — that is in the suite as this
        /// waiver's boundary.
        func retracted(dropped: [Int], classPositions: [Int],
                       survived: (String) -> Bool) -> Bool {
            dropped.contains { start in
                classPositions.contains { later in
                    later > start && survived(rawWords[later]) && markerBetween(start, later)
                }
            }
        }

        var kept: [Violation] = []
        var waivedAny = false

        for violation in violations {
            switch violation {
            case .dayLost(let day):
                let all = rawWords.indices.filter { dayNames.contains(rawWords[$0]) }
                let mine = all.filter { rawWords[$0] == day }
                if retracted(dropped: mine, classPositions: all,
                             survived: { rewriteSet.contains($0) }) {
                    waivedAny = true; continue
                }

            case .nameLost(let name):
                let all = rawWords.indices.filter { rawNames.contains(rawWords[$0]) }
                let mine = all.filter { rawWords[$0] == name }
                if retracted(dropped: mine, classPositions: all,
                             survived: { rewriteSet.contains($0) }) {
                    waivedAny = true; continue
                }

            case .numberLost(let value):
                let all = rawWords.indices.filter { !numbers(in: [rawWords[$0]]).isEmpty }
                let mine = all.filter { numbers(in: [rawWords[$0]]).contains(value) }
                let survived: (String) -> Bool = { word in
                    !numbers(in: [word]).isEmpty
                        && !numbers(in: [word]).isDisjoint(with: rewriteNumbers)
                }
                if retracted(dropped: mine, classPositions: all, survived: survived) {
                    waivedAny = true; continue
                }
                // Waiver 3 — middle values, numbers only, no marker needed.
                //
                // real-10 is "from 430 to 2 but I have a conflict at 2 so
                // I told them 245": the retraction is carried by "but I
                // have a conflict", which is not a marker word and never
                // will be without turning the list into a language model.
                // Position does the work instead.
                //
                // Two-value cases have no middle and stay fully protected:
                // "from 430 to 245" and "move Tuesday's to Thursday" both
                // still flag. Residual, accepted: an enumeration losing its
                // FIRST or LAST value ("flights at 9, 11 and 2 — book the
                // 11") still flags. That costs a retry, not a fact, and the
                // retry message restores it.
                if let first = all.first, let last = all.last,
                   !mine.isEmpty,
                   mine.allSatisfy({ $0 != first && $0 != last }),
                   mine.contains(where: { start in
                       all.contains { $0 > start && survived(rawWords[$0]) }
                   }) {
                    waivedAny = true; continue
                }

            default:
                break
            }
            kept.append(violation)
        }

        guard waivedAny else { return kept }

        // Rider A: a "no" spent as a retraction marker is not a stance.
        //
        // real-5 says "Actually, wait, no. Thursday is the all hands." That
        // "no" takes Thursday back; it is not the speaker disagreeing with
        // anything. Counting it as the negation baseline made a faithful
        // rewrite look like it had reversed a position.
        //
        // Rider B: a question superseded by a retraction is not one the
        // rewrite must preserve. "Can we do the demo on Thursday?" was
        // answered by the speaker themselves, two sentences later.
        //
        // Both riders only apply when something was actually waived, so an
        // ordinary negation or question is untouched.
        return kept.filter { violation in
            switch violation {
            case .negationLost:
                // Only a "no" spent inside a retraction phrase is exempt.
                return !markers.contains { rawWords[$0] == "no" || (rawWords[$0] == "wait" && $0 + 1 < rawWords.count && rawWords[$0 + 1] == "no") }
            case .questionLost: return false
            default: return true
            }
        }
    }

    /// Names as extraction sees them, for the successor test.
    private static func namesInRaw(_ raw: String) -> Set<String> {
        properNouns(in: raw)
    }

    /// Full check including invention, which needs the original text
    /// rather than only the extracted facts.
    static func verify(raw: String, rewrite: String,
                       context: AppContext = .general) -> [Violation] {
        var violations = verify(raw: extract(from: raw), rewrite: rewrite, context: context)
        violations = withoutRetractions(violations, raw: raw, rewrite: rewrite)

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
        // Built, not merely kept. Waiver 1 deleted `timeLost` on the
        // reasoning that a presence check "never protected against swaps",
        // which is true of real-6 — "end of next week not this week" has
        // both weeks in the raw, so any rewrite passes a subset test.
        //
        // It is NOT true of the single-value case, and the suite caught it:
        // "we can ship this week" → "we can ship next week" moves a
        // deadline by a week, and `timeLost` was the only thing catching
        // it. Deleting the class without this would have traded a false
        // positive for a silent lost week.
        //
        // Checking the invention side catches the same swap from the other
        // end, and does it without punishing the journey deletions the
        // prompt orders. "all morning" disappearing invents nothing.
        for time in newFacts.relativeTimes.subtracting(rawFacts.relativeTimes).sorted() {
            violations.append(.inventedTime(time))
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
        // **Amended again 2026-08-14** — Fable's ruling on
        // `review/FABLE-PROMPT-ceiling.md`. A fixed +2-word tolerance, on
        // top of the email allowance rather than instead of it.
        //
        // Two independent lines of evidence agreed. Four of the fifteen
        // rewrites the user accepted broke the ceiling, and a guard that
        // flags text the user approved is mis-specified by definition.
        // And after the scale-word fix, EVERY remaining violation across
        // the 31 transcripts on both candidate models was this one class
        // — all three of them a spoken fragment becoming a grammatical
        // sentence. made-13's entire violation was the word "It".
        //
        // Speech is elliptical and writing is not. Closing that ellipsis
        // costs a roughly constant number of function words, which is why
        // the tolerance is a constant and not the 10% alternative — a
        // percentage shrinks to one word exactly on the short Slack lines
        // where the repairs happen.
        //
        // The prompt had also been contradicting the ceiling
        // mechanically: its own worked example, "70 percent" for "70%",
        // costs a word the ceiling then charged for. Two rules fighting
        // over one word is how retries get manufactured.
        //
        // Two, specifically, and not three: made-11's +5 ("is maybe" →
        // "will take maybe") stays flagged, because that is
        // prose-ification rather than grammar. **Two words is grammar,
        // three is padding.**
        let spokenWords = tokenize(raw).count
        let writtenWords = tokenize(rewrite).count
        let ceiling = spokenWords + grammarTolerance
            + (context == .email ? emailShellAllowance : 0)
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
        //
        // A scale word is never a unit, even when it is also in
        // `unitWords`. "Three lakh" is the number 300,000, and the value
        // already carries it — pinning "lakh" as well demands the rewrite
        // keep a word whose whole meaning has moved into the digits, so
        // "300,000" read as a dropped unit.
        var found: Set<String> = []
        for (index, word) in words.enumerated()
        where unitWords.contains(word) && scaleWords[word] == nil {
            // Two tokens each way, not one. "Two MORE weeks" puts a
            // modifier between the number and its unit, so the spoken form
            // pinned no unit while the written "another two weeks" pinned
            // one — and the accepted rewrite of E1 was charged with
            // inventing a unit its own transcript contains.
            let lower = max(0, index - 2)
            let upper = min(words.count, index + 3)
            let neighbours = Array(words[lower..<index]) + Array(words[(index + 1)..<upper])
            let isQuantified = neighbours.contains { token in
                Int(token) != nil || spokenUnits[token] != nil
                    || spokenTens[token] != nil || quantityWords[token] != nil
                    // "two hundred megs" — the token touching "megs" is the
                    // scale, not the digit, so without this the spoken form
                    // pinned no unit and the written "200 megs" looked like
                    // an invented one.
                    || scaleWords[token] != nil
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
        let retracted = retractionSpans(in: words)
        var count = 0
        for (index, word) in words.enumerated() where negationMarkers.contains(word) {
            // The "no" in "wait no hold on" is the speaker changing their
            // mind, not a negation the rewrite has to carry. This was S2's
            // entire violation, in the accepted rewrite and on the eval
            // set both — the retraction waivers could not reach it because
            // they work on fact positions and this is a count.
            if retracted.contains(index) { continue }
            let window = words[max(0, index - 3)..<index]
            if window.contains(where: conditionalMarkers.contains) { continue }
            count += 1
        }
        // A negation can survive as a different construction. "Wanted you
        // to know now, not Wednesday" rewritten as "rather than Wednesday"
        // keeps the meaning exactly and loses the marker, which read as a
        // reversed statement — T4, in the wording the user accepted.
        for (index, word) in words.enumerated() where negationPhraseHeads.contains(word) {
            guard index + 1 < words.count else { continue }
            if negationPhrases.contains([word, words[index + 1]]) { count += 1 }
        }
        return count
    }

    /// Every index covered by a retraction phrase, not just where one starts.
    private static func retractionSpans(in words: [String]) -> Set<Int> {
        var covered: Set<Int> = []
        for start in retractionMarkerIndices(in: words) {
            for phrase in retractionPhrases where start + phrase.count <= words.count {
                if Array(words[start..<(start + phrase.count)]) == phrase {
                    covered.formUnion(start..<(start + phrase.count))
                }
            }
        }
        return covered
    }

    /// Two-word constructions that negate without a negation word.
    ///
    /// Counted on both sides, so swapping one for "not" in either
    /// direction is neutral rather than a lost negation.
    private static let negationPhrases: Set<[String]> = [
        ["rather", "than"], ["instead", "of"], ["as", "opposed"],
    ]
    private static let negationPhraseHeads: Set<String> = ["rather", "instead", "as"]

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
        normalizeWords(stripThousandsSeparators(stripListMarkers(text)))
            // A time separator splits rather than fuses: "11:00" must not
            // become the number 1100, which is what removing the colon
            // produced. It yields 11 and 0, and 0 is excluded from the
            // invention rule precisely so a written time cannot look like
            // a new fact.
            .replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .flatMap { splitDigitsFromLetters(String($0)) }
    }

    /// Drops "1." / "2)" where it opens a line — a list marker, not a
    /// quantity.
    ///
    /// The written twin of the "first, second, third" that
    /// `enumerationMarkers` already skips, and missing for the same
    /// reason it was: the guard was written before the prompt asked for
    /// lists. The prompt now *requires* enumerated speech to come back as
    /// a list, so the numbered form arrived as three invented numbers —
    /// on the accepted rewrite of E4, which is to say on the output we
    /// were aiming at.
    ///
    /// Anchored to the line start and capped at two digits so it cannot
    /// eat a real figure mid-sentence.
    private static func stripListMarkers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                let digits = trimmed.prefix(while: \.isNumber)
                guard !digits.isEmpty, digits.count <= 2,
                      let delimiter = trimmed.dropFirst(digits.count).first,
                      delimiter == "." || delimiter == ")" else { return String(line) }
                return String(trimmed.dropFirst(digits.count + 1))
            }
            .joined(separator: "\n")
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

    /// Words that multiply the number before them.
    ///
    /// "Forty five thousand" is 45,000, not 45. Without this the tens+units
    /// path stopped at 45, so a rewrite writing the figure the way anyone
    /// writes it — "45,000" — was scored as *both* losing 45 and inventing
    /// 45,000. Two violations for being correct.
    ///
    /// Found by pointing the stated rules at the fifteen rewrites the user
    /// accepted: it fires on N3, and on every rupee amount in real
    /// dictation. `lakh` and `crore` are here because this app's user
    /// dictates them, not for completeness.
    ///
    /// "k" earns its place the same way — "forty five k" is how the figure
    /// is spoken, and `splitDigitsFromLetters` already turns "45k" into
    /// "45" "k". It only ever multiplies a number that immediately
    /// precedes it, so a stray "K" cannot manufacture one.
    private static let scaleWords: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "k": 1_000,
        "lakh": 100_000, "lakhs": 100_000,
        "million": 1_000_000, "crore": 10_000_000, "crores": 10_000_000,
        "billion": 1_000_000_000,
    ]

    /// Words that carry a quantity without being numbers.
    ///
    /// Without these the subset rule storms: a faithful rewrite of "both
    /// options" as "2 options" would report an invented 2. Mapped on both
    /// sides, so the two spellings of one quantity compare equal — the
    /// same reason "fifteen" and 15 do.
    ///
    /// "half" was here mapping to 1 and is deliberately gone. It is not a
    /// count, and "I don't want to half commit and then flake" pinned the
    /// number 1 on a phrase containing no quantity at all — so the
    /// accepted rewrite of E2, which drops the phrase, was charged with
    /// losing a number nobody said. Same failure as the bare "one", which
    /// this table's neighbour already guards against.
    private static let quantityWords: [String: Int] = [
        "both": 2, "pair": 2, "couple": 2, "dozen": 12, "twice": 2,
        "single": 1, "once": 1, "thrice": 3,
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
            guard let (value, next) = numberPhrase(in: words, at: index) else {
                index += 1
                continue
            }
            found.insert(value)
            index = next
        }
        return found
    }

    /// One number and the index just past it, or nil where a token looks
    /// numeric but is not a fact.
    ///
    /// Split out of `numbers(in:)` so that scale words ("thousand",
    /// "lakh") can multiply whatever form the number arrived in, without
    /// repeating the absorption in each of the six branches below.
    private static func numberPhrase(in words: [String], at start: Int) -> (Int, Int)? {
        let word = words[start]
        var value: Int
        var index = start

        if let digits = Int(word) {
            value = digits
            index += 1
        }
        // "30th", "1st", "22nd" — a deadline is a number even when it
        // wears a suffix, and "cleared before the 30th" was previously
        // invisible to the guard entirely. Returns early: no one says
        // "the 30th thousand".
        else if let ordinal = ordinalValue(word) {
            return (ordinal, start + 1)
        }
        // "one" is usually prose, not a quantity. "quick one", "the
        // last one", "no one", "one more thing" — all pinned the
        // number 1 and then reported it lost when a faithful rewrite
        // dropped the phrase. It counts only when a unit follows, or
        // when a scale word makes it a figure in its own right ("one
        // lakh").
        else if word == "one" {
            let next = start + 1 < words.count ? words[start + 1] : ""
            guard unitWords.contains(next) || scaleWords[next] != nil else { return nil }
            value = 1
            index += 1
        }
        else if let quantity = quantityWords[word] {
            value = quantity
            index += 1
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
        else if enumerationMarkers.contains(word) {
            return nil
        }
        else if let unit = spokenUnits[word] ?? spokenOrdinals[word] {
            value = unit
            index += 1
        }
        else if let tens = spokenTens[word] {
            // "twenty five" is one number, not two.
            // "twenty five" and "twenty first" are both one number.
            value = tens
            index += 1
            if index < words.count,
               let unit = spokenUnits[words[index]] ?? spokenOrdinals[words[index]],
               unit < 10 {
                value += unit
                index += 1
            }
        }
        else {
            return nil
        }

        // Scale words multiply what came before, and chain: "two hundred
        // thousand" is 200,000. See `scaleWords` for why this was missing
        // and what it cost.
        while index < words.count, let scale = scaleWords[words[index]] {
            value *= scale
            index += 1
        }
        return (value, index)
    }
}
