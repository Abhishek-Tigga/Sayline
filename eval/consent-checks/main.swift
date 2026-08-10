// Checks SpokenConsent — the yes/no reader behind voice answers.
//
// Worth its own file because the failure is silent and expensive: reading
// "no" out of "now" declines something the user agreed to, and reading a
// yes out of an unclear answer deletes a reminder nobody confirmed. The
// trap cases below are the whole point; the obvious ones are there to stop
// a future tightening from breaking them.
//
// Run: swiftc -o /tmp/scchk Sources/Sayline/FollowUp.swift eval/consent-checks/main.swift && /tmp/scchk
import Foundation
var bad = 0
func check(_ text: String, _ expected: SpokenConsent) {
    let got = SpokenConsent.read(text)
    if got == expected { print("  ok    \"\(text)\" -> \(got)") }
    else { print("  FAIL  \"\(text)\" -> \(got), expected \(expected)"); bad += 1 }
}
print("clear yes")
for t in ["yes", "Yes.", "yeah", "sure", "OK", "go ahead", "do it", "yes please", "Delete it."] { check(t, .affirmative) }
print("\nclear no")
for t in ["no", "No.", "nope", "not now", "keep it", "never mind", "cancel", "forget it", "no thanks"] { check(t, .negative) }
print("\nthe traps")
check("now", .unclear)            // must not read as "no"
check("I know", .unclear)         // "know" is not "no"
check("nothing", .unclear)        // substring "no"
check("yes, but not now", .negative)   // both present, safe direction wins
check("open it", .affirmative)
check("okay let's do that", .affirmative)
print("\nunreadable -> costs one more question, never a guess")
for t in ["umm", "what?", "the dentist one", "", "banana"] { check(t, .unclear) }
print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
