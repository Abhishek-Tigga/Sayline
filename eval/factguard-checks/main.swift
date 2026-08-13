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
check("resolved self-correction fires (documented false positive)",
      violations("Let's do Friday, no wait, Thursday.", "Let's do Thursday.")
        .contains(.dayLost("friday")))

print("\nwhat must NOT fire — a guard that cries wolf gets ignored")
check("pure restructuring is allowed",
      violations("So um I was thinking, maybe, that we could, you know, ship it.",
                 "We could ship it.").isEmpty)
check("reordering is allowed",
      violations("Ship on Tuesday because the client asked for it.",
                 "The client asked for it, so we ship on Tuesday.").isEmpty)
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
check("this-week to next-week is caught",
      violations("we can ship this week", "we can ship next week")
        .contains(.timeLost("this week")))
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
      violations("calls with Mira's team", "calls with Mira and her team").isEmpty)

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

print("\nthe prompt block is built from the same extraction that verifies")
let pinned = FactGuard.promptBlock(for: FactGuard.extract(from: "Priya needs fifteen by Tuesday."))
check("pinned block names the number", pinned.contains("15"))
check("pinned block names the day", pinned.contains("Tuesday"))
check("pinned block names the name", pinned.contains("priya"))
check("nothing to pin means no block",
      FactGuard.promptBlock(for: FactGuard.extract(from: "let's ship it")).isEmpty)

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
