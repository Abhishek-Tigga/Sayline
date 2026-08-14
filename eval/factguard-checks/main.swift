// Checks FactGuard — work mode's whole safety contract.
//
// Clean mode promises "never lose a word". A rewrite cannot keep that, so
// Work mode promises instead that the FACTS survive: every number, day,
// name and negation actually spoken is still there, and no commitment
// appears that was never made. Structure is free.
//
// These cases are the ones the design named, each a real failure shape
// rather than an invented one. The last is a KNOWN FALSE POSITIVE, kept
// deliberately and asserted as firing, so the guard's documented limit is
// never rediscovered as a bug.
//
// Run: swiftc -o /tmp/fgchk Sources/Sayline/FactGuard.swift \
//        eval/factguard-checks/main.swift && /tmp/fgchk
import Foundation

var bad = 0

func check(_ label: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("  ok    \(label)") }
    else { print("  FAIL  \(label)"); bad += 1 }
}

func violations(_ raw: String, _ rewrite: String) -> [FactGuard.Violation] {
    FactGuard.verify(raw: raw, rewrite: rewrite)
}

print("extraction — the same call that pins the prompt and checks the result")

let facts = FactGuard.extract(from:
    "I told Priya we need fifteen units by Tuesday, but I don't think we should ship 3 of them.")
check("spoken numbers normalize to digits", facts.numbers.contains(15))
check("written numbers are found too", facts.numbers.contains(3))
check("day names are found", facts.days.contains("tuesday"))
check("proper nouns are found", facts.names.contains("priya"))
check("negations are counted", facts.negationCount >= 1)

// A capitalized first word is not a name. This one matters: every
// transcript starts with one, and a false name costs a real fallback.
let sentenceStart = FactGuard.extract(from: "The meeting is on Friday. Sarah will join.")
check("sentence-initial words are not names", !sentenceStart.names.contains("the"))
check("names after the first word are found", sentenceStart.names.contains("sarah"))
check("day names are not doubled as names", !sentenceStart.names.contains("friday"))

print("\ncompound spoken numbers")
check("twenty five is one number", FactGuard.extract(from: "about twenty five people").numbers.contains(25))
check("and not two", !FactGuard.extract(from: "about twenty five people").numbers.contains(20))

print("\nthe five named failure cases")

// 1 · The Tuesday -> Monday day swap.
check("day swap is caught",
      violations("Let's move the review to Tuesday.",
                 "Let's move the review to Monday.")
        .contains(.dayLost("tuesday")))

// 2 · The invented "I'll" commitment. The model must never put the user
// on the hook for something they did not say.
check("invented commitment is caught",
      violations("The deck needs another pass before Thursday.",
                 "I'll take another pass at the deck before Thursday.")
        .contains(.inventedCommitment("i'll")))

check("a commitment that WAS spoken is not flagged",
      violations("I'll take another pass at the deck.",
                 "I'll revise the deck.")
        .isEmpty)

check("\"I will\" spoken and \"I'll\" written is the same promise",
      !violations("I will send the numbers over.", "I'll send the numbers over.")
        .contains(.inventedCommitment("i'll")))

// 3 · 15 -> 50, the digit that changes an order.
check("changed number is caught",
      violations("We need fifteen units.", "We need 50 units.")
        .contains(.numberLost(15)))

check("the same number written differently is fine",
      violations("We need fifteen units.", "We need 15 units.").isEmpty)

// 4 · The negation flip — meaning reversed, every word plausible.
check("negation flip is caught",
      violations("I don't think we should ship on Friday.",
                 "We should ship on Friday.")
        .contains(where: { if case .negationLost = $0 { return true }; return false }))

check("a rephrased negation is allowed",
      !violations("I don't think we should ship.", "I think we shouldn't ship.")
        .contains(where: { if case .negationLost = $0 { return true }; return false }))

// 5 · KNOWN FALSE POSITIVE, asserted as such.
//
// "Friday, no wait, Thursday" resolves to Thursday, and a good rewrite
// drops Friday — correctly. The guard sees a day it pinned go missing and
// fires. It falls back to the user's exact words, which is the safe
// direction, and it is the cost of having no model in the guard path.
//
// This assertion is here so the limit is a recorded decision rather than
// a surprise. If someone later teaches the guard to resolve corrections,
// this case flips and SHOULD be updated — deliberately, not silently.
// FLIPPED 2026-08-14, deliberately, exactly as the note above asked.
// Fable's marker-gated waiver resolves the correction, so this no longer
// fires — the limit is lifted rather than recorded.
check("a resolved self-correction no longer fires",
      !violations("Let's do Friday, no wait, Thursday.", "Let's do Thursday.")
        .contains(.dayLost("friday")))

print("\nwhat must NOT fire — a guard that cries wolf gets ignored")
check("pure restructuring is allowed",
      violations("So um I was thinking, maybe, that we could, you know, ship it.",
                 "We could ship it.").isEmpty)
// Asserts on the property it exists for, not on total silence. The
// Voice 2 length ceiling also fires here — the rewrite is two words
// longer — and that is correct under rule 5a; this case is about whether
// reordering loses a fact, which it does not. One case, one property.
check("reordering loses no facts",
      !violations("Ship on Tuesday because the client asked for it.",
                  "The client asked for it, so we ship on Tuesday.")
        .contains(where: { if case .longerThanSpeech = $0 { return false }; return true }))
check("names and numbers surviving a heavy rewrite is fine",
      violations("um so Priya said like fifteen units by Tuesday I think",
                 "Priya needs 15 units by Tuesday.").isEmpty)

print("\nfound by real dictation, 2026-08-13 — invented cases missed all four")

// Every one of these came from the user's own speech. The suite passed
// 26 cases without them.

// "Doesn't that work for you" — a contraction read as a name.
check("contractions are not names",
      !FactGuard.extract(from: "So we move it to Friday. Doesn't that work for you?")
        .names.contains("doesnt"))

// "Can we do the demo on Thursday? ... Yeah, Monday afternoon."
check("sentence-opening Can is not a name",
      !FactGuard.extract(from: "Can we do the demo on Thursday?").names.contains("can"))
check("Yeah is not a name",
      !FactGuard.extract(from: "Yeah, Monday afternoon works better.").names.contains("yeah"))

// "the one from design well for 45,000 rupees" — an invoice amount split
// into 45 and 0 by the thousands comma. The number that matters most in
// the sentence was the one being mangled.
let invoice = FactGuard.extract(from: "approve the vendor invoice for 45,000 rupees")
check("thousands separators survive", invoice.numbers.contains(45000))
check("and do not become two numbers", !invoice.numbers.contains(45) && !invoice.numbers.contains(0))

// "finance needs it cleared before the 30th" — an ordinal deadline,
// previously invisible to the guard entirely.
check("ordinals are found",
      FactGuard.extract(from: "finance needs it cleared before the 30th").numbers.contains(30))
check("ordinal words too",
      FactGuard.extract(from: "due on the twenty first").numbers.contains(21))

// Times as digits: "move it from 430 to 2 ... I told them 245"
let times = FactGuard.extract(from: "move it from 430 to 2 but I told them 245")
check("times are kept as spoken digits", times.numbers.contains(430) && times.numbers.contains(245))

print("\nFable review, 2026-08-13 — gaps found by reading, ranked by damage")

// B · an invented person is worse than a dropped one. The model must not
// put a name in the user's mouth.
check("invented name is caught",
      violations("someone should pick up the migration this week",
                 "Ankit should pick up the migration this week.")
        .contains(.inventedName("ankit")))
check("a name that WAS spoken is not an invention",
      !violations("Rohan can't make Wednesday", "Rohan cannot make Wednesday.")
        .contains(.inventedName("rohan")))

// Negation, the other direction. A rewrite that ADDS a negation to a
// sentence that had none reverses meaning just as completely.
check("negation added from zero is caught",
      violations("I think we should ship on Friday.",
                 "I don't think we should ship on Friday.")
        .contains(where: { if case .negationAdded = $0 { return true }; return false }))
check("adding a second negation to a sentence that had one is allowed",
      !violations("I don't think we should ship.",
                  "I don't think we should ship, and I don't want to argue.")
        .contains(where: { if case .negationAdded = $0 { return true }; return false }))

// Gap 1 · relative time. real-6: "end of next week not this week" — a
// rewrite swapping those moves a deadline by a week and passes today.
check("relative weeks are pinned",
      FactGuard.extract(from: "realistically end of next week not this week")
        .relativeTimes.contains("next week"))
// Now caught from the INVENTION side. `timeLost` was deleted as a class
// on 2026-08-14 because all it caught was journey deletions the prompt
// orders — but this case proved that reasoning incomplete: a single-value
// swap moves a deadline by a week and only that class was catching it.
// The invented-time check closes the same hole without punishing "all
// morning" disappearing, which invents nothing.
check("this-week to next-week is still caught, from the other side",
      violations("we can ship this week", "we can ship next week")
        .contains(.inventedTime("next week")))
check("tomorrow is pinned",
      FactGuard.extract(from: "let's discuss at the sync tomorrow").relativeTimes.contains("tomorrow"))

// Gap 2 · months were in the stopword list, so "March deadline" ->
// "April deadline" passed.
check("months are pinned",
      FactGuard.extract(from: "I don't think we should commit to the March deadline")
        .months.contains("march"))
check("a changed month is caught",
      violations("commit to the March deadline", "commit to the April deadline")
        .contains(.monthLost("march")))

// Gap 3 · units. "25 megs" -> "25 GB" keeps the number and changes the
// meaning by a thousand.
check("units are pinned",
      FactGuard.extract(from: "a file bigger than 25 megs").units.contains("megs"))
check("a changed unit is caught",
      violations("a file bigger than 25 megs", "a file bigger than 25 GB")
        .contains(.unitLost("megs")))
check("currency is a unit",
      violations("45,000 rupees", "45,000 dollars").contains(.unitLost("rupees")))

// Gap 4 · fused suffixes. real-1: "Friday morning like 11ish" — the
// meeting time was invisible.
check("11ish yields 11",
      FactGuard.extract(from: "Friday morning like 11ish").numbers.contains(11))

// Smaller ones Fable named.
check("barely counts as a negation",
      FactGuard.extract(from: "barely anyone clicked it").negationCount >= 1)
check("possessives normalize to the name",
      FactGuard.extract(from: "the customer calls with Mira's team").names.contains("mira"))
check("so a rewrite saying Mira is not a dropped name",
      !violations("calls with Mira's team", "calls with Mira and her team")
        .contains(where: { if case .nameLost = $0 { return true }
                           if case .inventedName = $0 { return true }
                           return false }))

// The "we'll" storm: rewrites routinely turn "let's" into "we'll", and
// flagging that would dominate the fallback rate for no safety gain.
check("we'll is not treated as an invented commitment",
      violations("let's do Monday afternoon", "We'll do Monday afternoon.")
        .isEmpty)
check("but I'll still is",
      violations("the deck needs another pass", "I'll take another pass at the deck.")
        .contains(.inventedCommitment("i'll")))

print("\nfound by the model bake-off, 2026-08-13 — the guard fighting the mode")

// Real output from gpt-4.1-mini on the user's real-1, flagged as losing a
// negation. The rewrite is CORRECT: it dropped "Doesn't that work for
// you?", a rhetorical question that is thinking-out-loud, and the
// negation went with the clause.
//
// Decision 1 says deleting thinking-out-loud is expected behaviour, so a
// rule that fires when a dropped clause takes a negation with it is the
// guard fighting the mode's whole purpose. Negation was 8 of 13
// violations across models — the dominant class, and inflating every
// score.
//
// Narrowed: losing SOME negation is allowed, losing ALL of them is not.
// "I don't think we should ship" -> "We should ship" still fires, because
// that goes to zero.
check("dropping a rhetorical question with its negation is allowed",
      !violations("Rohan said he can't make Wednesday anymore. So I'm thinking we move it to Friday. Doesn't that work for you?",
                  "Rohan can't make Wednesday anymore. We should move it to Friday.")
        .contains(where: { if case .negationLost = $0 { return true }; return false }))

check("but losing the last negation still fires",
      violations("I don't think we should ship on Friday.",
                 "We should ship on Friday.")
        .contains(where: { if case .negationLost = $0 { return true }; return false }))

check("two negations down to zero fires",
      violations("I don't think we should ship and I can't support it.",
                 "We should ship and I support it.")
        .contains(where: { if case .negationLost = $0 { return true }; return false }))

print("\nFable review 2 — the subset rule: nothing quantifiable may be invented")

// The finding that stopped stage 3. Real output from llama-3.3-70b on
// the user's real-1: a faithful rewrite with an invented sentence
// appended, which the guard called clean because it only ever asked
// whether the user's facts survived.
check("the real-1 invented number is caught",
      violations("Rohan said he can't make Wednesday anymore. So I'm thinking we move it to Friday morning like 11ish.",
                 "Rohan can no longer make it on Wednesday, so we are moving the design review to Friday morning at 11. This change may not work for everyone, as there are 2 potential issues with the new time.")
        .contains(.inventedNumber(2)))

// made-15: an appended sentence, same shape.
check("an invented day is caught",
      violations("the deck needs another pass", "The deck needs another pass before Monday.")
        .contains(.inventedDay("monday")))
check("an invented month is caught",
      violations("we should ship soon", "We should ship in April.")
        .contains(.inventedMonth("april")))
check("an invented unit is caught",
      violations("the export is too big", "The export is 400 megs, too big for email.")
        .contains(.inventedUnit("megs")))

// Normalization, or the rule storms on faithful rewrites.
check("both -> 2 is not an invention",
      !violations("both teams signed off", "2 teams signed off")
        .contains(.inventedNumber(2)))
check("a couple -> 2 is not an invention",
      !violations("a couple of people asked", "2 people asked")
        .contains(.inventedNumber(2)))
check("11ish -> 11:00 is not an invented zero",
      violations("Friday morning like 11ish", "Friday morning at 11:00").isEmpty)
check("a bare zero is never an invention",
      !violations("the callback returns four zero three", "The callback returns 403.")
        .contains(.inventedNumber(0)))

print("\nconditional negations are restructuring, not reversal")
// real-8, a faithful rewrite flagged by the first version of the rule.
check("if-not phrasing is allowed",
      !violations("finance needs it cleared before the 30th or it slips to the next month cycle",
                  "The invoice must be cleared before the 30th. If it is not cleared, it will slip to next month.")
        .contains(where: { if case .negationAdded = $0 { return true }; return false }))
check("but a bare assertion reversed still fires",
      violations("we should ship on Friday", "We shouldn't ship on Friday.")
        .contains(where: { if case .negationAdded = $0 { return true }; return false }))

print("\n\"one\" is prose unless a unit follows")
check("quick one is not a number", !FactGuard.extract(from: "hey quick one for you").numbers.contains(1))
check("the last one is not a number", !FactGuard.extract(from: "he wasn't on the last one").numbers.contains(1))
check("no one is not a number", !FactGuard.extract(from: "no one clicked it").numbers.contains(1))
check("one more thing is not a number", !FactGuard.extract(from: "one more thing before we go").numbers.contains(1))
check("one week IS a number", FactGuard.extract(from: "give it one week").numbers.contains(1))
check("one hour IS a number", FactGuard.extract(from: "it took one hour").numbers.contains(1))
check("twenty one still resolves", FactGuard.extract(from: "due on the twenty first").numbers.contains(21))
// The hole this leaves is closed from the other side.
check("one bug -> two bugs is caught by the subset rule",
      violations("there is one bug in checkout", "There are two bugs in checkout.")
        .contains(.inventedNumber(2)))

print("\nFable stage-6 review — symbol units, confirmed live as a false positive")

// Models overwhelmingly write symbols for money and percentages, so this
// fired on exactly the sentences the guard most exists to protect: a
// retry (which uses symbols again) and then a fallback, on a faithful
// rewrite.
check("percent symbol is the same unit as the word",
      violations("the backend work is maybe 60 percent done", "The backend is 60% done.").isEmpty)
check("rupee symbol is the same unit as the word",
      violations("the invoice is for 45,000 rupees", "The invoice is for ₹45,000.").isEmpty)
check("dollar symbol is the same unit as the word",
      violations("it cost 200 dollars", "It cost $200.").isEmpty)
// The equivalence is WITHIN a currency, never across it.
check("a currency swap is still caught",
      violations("the invoice is for 45,000 rupees", "The invoice is for $45,000.")
        .contains(where: { if case .unitLost = $0 { return true }; return false }))
check("and the swapped-in currency is flagged as invented",
      violations("the invoice is for 45,000 rupees", "The invoice is for $45,000.")
        .contains(.inventedUnit("dollars")))

print("\nFable stage-6 review — a question answered is a question lost")

// Both observed qualitative inventions share one mechanical property:
// the speaker asked something and the rewrite contains no question. That
// is checkable without semantics.
check("the real-1 rhetorical question invention is caught",
      violations("So I'm thinking we move it to Friday morning like 11ish. Doesn't that work for you or is Friday bad?",
                 "Let's move the design review to Friday morning around 11. Friday morning at 11 won't work if you have a conflict, but it's an option.")
        .contains(where: { if case .questionLost = $0 { return true }; return false }))
check("the email-register version is caught too",
      violations("Doesn't that work for you or is Friday bad?",
                 "Friday is not confirmed as a suitable alternative, as it is not known if it works or if Friday is bad.")
        .contains(where: { if case .questionLost = $0 { return true }; return false }))
check("keeping the question passes",
      !violations("Doesn't that work for you or is Friday bad?",
                  "Does Friday morning work for you?")
        .contains(where: { if case .questionLost = $0 { return true }; return false }))
// Merging two questions into one is faithful; the rule is all-or-nothing,
// the same lesson the negation count had to learn.
check("merging two questions into one is allowed",
      !violations("Can we do Friday? Or is that bad for you?", "Does Friday work for you?")
        .contains(where: { if case .questionLost = $0 { return true }; return false }))
// Conversational tics are not questions worth protecting.
check("a trailing tic is not a question",
      !violations("we should ship on Friday, right?", "We should ship on Friday.")
        .contains(where: { if case .questionLost = $0 { return true }; return false }))
check("you know? is not a question either",
      !violations("it just sits there forever, you know?", "It sits there forever.")
        .contains(where: { if case .questionLost = $0 { return true }; return false }))
check("a statement rewritten as a statement is untouched",
      violations("we should ship on Friday", "We should ship on Friday.").isEmpty)

print("\nfound live 2026-08-13 — enumeration markers are structure, not facts")

// The user asked for dictated lists to become bullets. Doing that drops
// "first/second/third", which were pinned as 1/2/3 — so the guard fell
// back on the exact output the user wanted. The prompt was fighting the
// guard.
//
// Same shape as the "one" rule: a bare small ordinal in speech is almost
// always an enumeration marker. Digit ordinals ("30th") and compounds
// ("twenty first") stay facts, because that is how a real date is said.
check("bare first/second/third are not numbers",
      FactGuard.extract(from: "three reasons: first the cost, second the timeline, third nobody asked")
        .numbers.isEmpty == false)  // "three" is still a number
check("but the ordinals themselves are not pinned",
      !FactGuard.extract(from: "first the cost, second the timeline").numbers.contains(1))
check("so a dictated list can become bullets without falling back",
      violations("there are three reasons we shouldn't do it first the cost second the timeline and third nobody asked",
                 "We shouldn't do it, for three reasons:\n- the cost\n- the timeline\n- nobody asked")
        .isEmpty)
check("digit ordinals are still facts",
      FactGuard.extract(from: "cleared before the 30th").numbers.contains(30))
check("compound spoken ordinals are still facts",
      FactGuard.extract(from: "due on the twenty first").numbers.contains(21))

print("\nVoice 2 — the length ceiling: a rewrite may not be longer than the speech")

// Rule 5a. Padding cannot survive a ceiling, and the B2 meta-sentence
// would have died on it without any prompt change at all.
check("a padded rewrite is caught",
      violations("there are three reasons. first the quote. second the timeline. third nobody asked for it",
                 "There are three reasons: the quote, the timeline, and that nobody asked for it. These are the first, second, and third reasons, respectively.")
        .contains(where: { if case .longerThanSpeech = $0 { return true }; return false }))
check("a faithful compression passes",
      !violations("so um I was thinking maybe that we could you know ship it on Tuesday",
                  "We could ship it on Tuesday.")
        .contains(where: { if case .longerThanSpeech = $0 { return true }; return false }))

// A short utterance cannot meaningfully compress, so the ceiling is
// "no longer than" rather than "strictly shorter" below ~10 words.
check("a short utterance may stay the same length",
      !violations("push it to Tuesday", "Push it to Tuesday.")
        .contains(where: { if case .longerThanSpeech = $0 { return true }; return false }))
check("but a short utterance may still not grow",
      violations("push it to Tuesday",
                 "I would like to propose that we push it to Tuesday if that works.")
        .contains(where: { if case .longerThanSpeech = $0 { return true }; return false }))

print("\nVoice 2 — no synonym upgrades, no softened positions")

// Rule 2 and rule 3. Every entry below arrives with the real rewrite
// that motivated it, per the standing lexicon rule.
check("utilize is an upgrade",
      violations("we should use the new endpoint", "We should utilize the new endpoint.")
        .contains(.formalityUpgrade("utilize")))
check("I would like to propose is an upgrade",
      violations("let's move it to Thursday", "I would like to propose moving it to Thursday.")
        .contains(.formalityUpgrade("i would like to propose")))
check("not fully aligned is a softened position",
      violations("I don't agree with the copy", "I'm not fully aligned on the copy.")
        .contains(.formalityUpgrade("not fully aligned")))
check("as per is an upgrade",
      violations("like we said on the call", "As per the call.")
        .contains(.formalityUpgrade("as per")))

// Observed live, 2026-08-13, in this user's own session.
check("let us, from \"let\u{2019}s do Thursday\"",
      violations("let's do Thursday", "Let us do Thursday.")
        .contains(.formalityUpgrade("let us")))
check("do not, from \"we don\u{2019}t think we should\"",
      violations("we don't think we should do it on Saturday",
                 "We do not think we should do it on Saturday.")
        .contains(.formalityUpgrade("do not")))

// The word being banned is only a violation when the SPEAKER did not use
// it. A guard that forbids the user's own vocabulary is worse than none.
check("the speaker's own formal words are never flagged",
      !violations("as per the contract we should kindly ask them",
                  "As per the contract, we should kindly ask them.")
        .contains(where: { if case .formalityUpgrade = $0 { return true }; return false }))
check("and do not spoken as do not is fine",
      !violations("we do not agree with this", "We do not agree with this.")
        .contains(where: { if case .formalityUpgrade = $0 { return true }; return false }))

print("\nthe prompt block is built from the same extraction that verifies")
let pinned = FactGuard.promptBlock(for: FactGuard.extract(from: "Priya needs fifteen by Tuesday."))
check("pinned block names the number", pinned.contains("15"))
check("pinned block names the day", pinned.contains("Tuesday"))
check("pinned block names the name", pinned.contains("priya"))
check("nothing to pin means no block",
      FactGuard.promptBlock(for: FactGuard.extract(from: "let's ship it")).isEmpty)

// MARK: - Name extraction, after NLTagger replaced the capitalization rule
//
// Every case here comes from live data on 2026-08-14, when phantom names
// were measured as the largest driver of a ~50% retry rate — each phantom
// costing a full extra API round trip. The old rule pinned any capitalized
// word not on a stopword list; dictation capitalizes every sentence start.
//
// These run in both directions on purpose. A phantom costs latency; a
// MISSED name costs protection silently, which is worse. Testing only the
// phantoms would have shipped a tagger that drops "Priya" after "and".

print("\nnames — phantoms rejected, real names still caught")

func names(_ text: String) -> Set<String> {
    FactGuard.extract(from: text).names
}

check("a sentence-initial verb is not a name",
      names("See, the way things work here. Make use of everything.").isEmpty)
check("ordinals and connectives are not names",
      names("Okay, there are three things. First, ship it. After that, rest.").isEmpty)
check("a real name starting a sentence is still caught",
      names("Priya needs 15 units by Friday.") == ["priya"])
check("a name after a conjunction is not dropped",
      names("Ask Nikhil and Priya to review it.") == ["nikhil", "priya"])
check("an imperative verb before a name is not itself a name",
      names("Tell Rohit the deploy is done.") == ["rohit"])
check("a multi-word place name pins its distinctive words",
      names("Sterling Essentia Apartment") == ["sterling", "essentia"])
check("and does so mid-sentence too",
      names("I spoke to Meera about the Sterling Essentia lease.")
        == ["meera", "sterling", "essentia"])

// MARK: - The ceiling, after the 26/26 refusal
//
// S2, live on 2026-08-14: the first attempt broke a cluster of facts, the
// corrective retry came back at 26 words for 26 spoken, and the guard
// refused it because the rule demanded strictly fewer. A possibly-good
// rescue was thrown away over one word, and the user got their raw detour
// verbatim — "Wait no hold on" included.

print("\nthe ceiling permits equal length, and allows for an email shell")

func tooLong(_ raw: String, _ rewrite: String, _ context: AppContext = .general) -> Bool {
    FactGuard.verify(raw: raw, rewrite: rewrite, context: context)
        .contains { if case .longerThanSpeech = $0 { return true }; return false }
}

let twentySix = Array(repeating: "word", count: 26).joined(separator: " ")
check("equal length is not padding — the S2 refusal",
      !tooLong(twentySix, twentySix))
check("one word longer still is padding",
      tooLong(twentySix, twentySix + " extra"))
check("an email shell may add words",
      !tooLong(twentySix, "Hi Priya, " + twentySix + " Best, Abhishek", .email))
check("but the shell allowance is not a blank cheque",
      tooLong(twentySix, twentySix + " " + Array(repeating: "pad", count: 20).joined(separator: " "), .email))
check("a short utterance may still not grow, unchanged",
      tooLong("push it to Tuesday", "Please push it to Tuesday at some point"))

// MARK: - Retraction waivers (Fable's decision, 2026-08-14)
//
// Tolerance, not deletion: the model already chose what to write, and
// these only stop the guard punishing a choice the speaker made aloud.
// The boundary cases matter more than the waivers — a waiver that is too
// eager loses a fact silently, which is the direction that must never be
// cheap.

print("\nretraction waivers — and the boundaries that must still flag")

func kinds(_ raw: String, _ rewrite: String) -> [String] {
    FactGuard.verify(raw: raw, rewrite: rewrite).map(\.kind)
}

// real-5, live: every violation here was the guard punishing a retraction.
check("a retracted day, its marker-no and its superseded question all clear",
      kinds("Can we do the demo on Thursday? Actually, wait, no. Thursday is the all hands. Let's do Monday. Yeah, Monday afternoon works better anyways.",
            "Let's do the demo on Monday afternoon.").isEmpty)

// real-10, live: the retraction is carried by "but I have a conflict",
// which is not a marker word — position does the work.
check("a middle number the speaker talked themselves out of clears",
      !kinds("they asked to move it from 430 to 2 but I have a conflict at 2 so I told them 245",
             "Move the call from 430 to 245.").contains("number"))

// THE BOUNDARY. No marker between the days, so both are real.
check("no marker between two days means a dropped day still flags",
      kinds("move Tuesday's meeting to Thursday", "Move the meeting to Thursday.")
        .contains("day"))

check("a two-value number range has no middle and stays protected",
      kinds("move it from 430 to 245", "Move it to 245.").contains("number"))

check("an ordinary negation is untouched when nothing was retracted",
      kinds("I don't think we should ship this", "We should ship this.")
        .contains("negation"))

check("an ordinary question is untouched when nothing was retracted",
      kinds("can you look at the deck today?", "Look at the deck today.")
        .contains("question-lost"))

// Waiver 1: the class is gone, but only in the losing direction.
check("dropping the journey is no longer a violation",
      !kinds("i've been going back and forth on this all morning but we should park it",
             "We should park it.").contains("relative-time"))
check("but an invented relative time is still caught",
      kinds("we should park the export feature", "We should park the export feature next week.")
        .contains("invented-relative-time"))

// Scale words. Found 2026-08-14 by scoring the fifteen rewrites the user
// accepted against our own rules: the tens+units path stopped at 45, so
// writing the figure the way a person writes it was two violations at
// once — the number lost AND the number invented. It also cost
// gpt-4.1-mini the Phase C bake-off, at 19% that was really 10%.
print("\nspoken numbers survive being written as figures")
check("a thousands scale word multiplies rather than being ignored",
      kinds("I said the invoice was forty five thousand", "The invoice was 45,000.").isEmpty)
check("so does hundred",
      kinds("we need two hundred users", "We need 200 users.").isEmpty)
check("and lakh, which is how this app's user says it",
      kinds("the budget is about three lakh", "The budget is about 300,000.").isEmpty)
check("scales chain",
      kinds("that's two hundred thousand", "That's 200,000.").isEmpty)
check("a unit beside a scale word is still pinned",
      kinds("we need two hundred megs", "We need 200 GB.").contains("unit"))
check("the scale word itself is not a unit to preserve",
      !kinds("the budget is about three lakh", "The budget is about 300,000.").contains("unit"))
// The boundary: dropping the scale changes the figure a thousandfold.
check("dropping the scale is still caught",
      kinds("budget is fifty thousand", "Budget is fifty.").contains("number"))
check("and a genuinely invented number still is",
      kinds("we need two servers", "We need 200 servers.").contains("invented-number"))

// Digit list markers — the written twin of the "first, second" that
// `enumerationMarkers` already skipped. The prompt *requires* enumerated
// speech to come back as a list, so this fired on exactly the shape we
// asked for.
print("\na numbered list is a shape, not three new facts")
check("line-leading digit markers are not invented numbers",
      kinds("three things really, the launch is on track, hiring is done, legal is stuck",
            "Three things:\n1. Launch on track\n2. Hiring done\n3. Legal stuck")
        .isEmpty)
check("but a digit mid-sentence is still a fact",
      kinds("we have three things", "We have 7 things.").contains("invented-number"))

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
