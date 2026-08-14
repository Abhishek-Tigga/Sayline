import Foundation

var bad = 0
func check(_ name: String, _ ok: Bool) {
    print("  \(ok ? "ok  " : "FAIL") \(name)"); if !ok { bad += 1 }
}
func eq(_ name: String, _ input: String, _ want: String) {
    let got = SpeechPatterns.apply(input)
    print("  \(got == want ? "ok  " : "FAIL") \(name)")
    if got != want { bad += 1; print("        want: \(want)\n        got : \(got)") }
}

// The FIX table the user legislated in Clean round 1. Nothing else belongs
// here; additions are a product decision.
print("grammar policy — FIX")
eq("\"I don't think so X\" drops the so",
   "I don't think so caching is the issue here.",
   "I don't think caching is the issue here.")
eq("...with a curly apostrophe too",
   "I don\u{2019}t think so caching is the issue.",
   "I don\u{2019}t think caching is the issue.")
eq("\"revert back\" keeps their verb",
   "Please revert back to me by evening.", "Please revert to me by evening.")
eq("\"discussed about\" loses the about",
   "once you have discussed about the pricing", "once you have discussed the pricing")
eq("\"the both\" loses the the",
   "inform the both teams", "inform both teams")
eq("\"Myself, I will\" becomes I'll",
   "Myself, I will handle the client call.", "I'll handle the client call.")
eq("...without the comma as well",
   "Myself I will handle the client call.", "I'll handle the client call.")

// Identity, not error. A better model will itch to fix these; nothing in
// this file may.
print("\ngrammar policy — KEEP (protected phrasing)")
eq("prepone survives", "Just prepone the standup to nine.",
   "Just prepone the standup to nine.")
eq("\"do one thing\" survives", "Do one thing, just prepone the standup.",
   "Do one thing, just prepone the standup.")
eq("\"you please\" survives", "You please take care of the demo setup.",
   "You please take care of the demo setup.")
check("all three are named in the protected list",
      Set(SpeechPatterns.protectedPhrases) == ["prepone", "do one thing", "you please"])

// "I don't think" without a following clause is a complete sentence and
// the "so" is not the construction — the boundary the lookahead buys.
print("\nboundaries")
eq("a bare \"I don't think so.\" is left alone",
   "I don't think so.", "I don't think so.")
eq("\"revert\" alone is untouched", "Please revert by evening.",
   "Please revert by evening.")
eq("\"both teams\" without the article is untouched",
   "inform both teams", "inform both teams")

print("\ncontractions — PREFER")
eq("I will -> I'll", "I will send it tonight.", "I'll send it tonight.")
eq("you have -> you've before a participle",
   "once you have got the keys", "once you've got the keys")
eq("it is -> it's before a determiner",
   "it is a known issue", "it's a known issue")

// E1's transcript, and the spacing artifact from the same round.
print("\nnumber normalization")
eq("forty seven and a half thousand -> 47,500",
   "the budget is forty seven and a half thousand",
   "the budget is 47,500")
eq("...and the swapped wording the model started emitting",
   "the budget is forty seven thousand and a half", "the budget is 47,500")
eq("plain scale still works", "the budget is forty seven thousand",
   "the budget is 47,000")
// Three-digit grouping, pinned. This machine's locale would give
// 2,50,000 — see `group(_:)`. Whether Indian grouping should be an
// option is in BACKLOG.md.
eq("two and a half lakh -> 250,000", "about two and a half lakh",
   "about 250,000")
eq("\"40 000\" spacing -> 40,000", "release 40 000 for the invoice",
   "release 40,000 for the invoice")
eq("a year is not a thousands group", "in 2024 15 people joined",
   "in 2024 15 people joined")
eq("a non-number phrase is left alone", "a thousand apologies",
   "a thousand apologies")

// Verbatim from the log, 2026-08-14 — E1 failed live because the eval
// had only ever been given the spelled-out form.
eq("the live form: digits, with the article",
   "the budget is 47 and a half thousand", "the budget is 47,500")
eq("the live form: digits, article dropped",
   "the budget is 47 and half thousand", "the budget is 47,500")
eq("the whole logged sentence",
   "The call moved from 430 to 245 and the budget is 47 and a half thousand.",
   "The call moved from 4:30 to 2:45 and the budget is 47,500.")
eq("digits with a plain scale", "release 40 thousand", "release 40,000")

print("\nclock times — ruled in 2026-08-14")
eq("spoken time after a cue", "the call moved from four thirty to two forty five",
   "the call moved from 4:30 to 2:45")
eq("digit time after a cue", "just prepone the standup to 930",
   "just prepone the standup to 9:30")
eq("o'clock", "let's meet at four o'clock", "let's meet at 4:00")
// The money/time ambiguity the cue and the 1-12 hour exist to settle.
eq("money is not a time", "release forty five thousand for the invoice",
   "release 45,000 for the invoice")
eq("money after a cue is still money", "the budget is up to forty seven thousand",
   "the budget is up to 47,000")
eq("no cue, no time", "we need three fifteen minute slots",
   "we need three fifteen minute slots")
eq("an invalid hour is left alone", "call me at 1330", "call me at 1330")

print("\nteam names — ruled in 2026-08-14")
eq("finance is a team", "tell finance to release the invoice",
   "tell Finance to release the invoice")
eq("already capitalized stays", "tell Finance to release", "tell Finance to release")
eq("not a substring", "refinanced the loan", "refinanced the loan")

print("\nidempotence — this runs on text a cooperative model may have already fixed")
let once = SpeechPatterns.apply("Myself, I will revert back about the both teams by forty seven and a half thousand")
check("applying twice changes nothing", SpeechPatterns.apply(once) == once)

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
