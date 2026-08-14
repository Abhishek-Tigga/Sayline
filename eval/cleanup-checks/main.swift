import Foundation

var bad = 0
func eq(_ name: String, raw: String, llm: String, _ want: String) {
    let got = SpeechPatterns.apply(TranscriptCleanupValidator.validate(raw: raw, cleaned: llm))
    print("  \(got == want ? "ok  " : "FAIL") \(name)")
    if got != want { bad += 1; print("        want: \(want)\n        got : \(got)") }
}

// Punctuation. `smooth` used to strip every comma and semicolon that
// preceded a lowercase word — which is nearly every correct one. Clean's
// baseline round read that as small-model behaviour and pointed a model
// A/B at it; fed the user's own expected output, the validator removed
// the commas itself.
print("punctuation survives the merge")
eq("greeting comma", raw: "hey Priya quick question is the staging environment back up",
   llm: "Hey Priya, quick question. Is the staging environment back up?",
   "Hey Priya, quick question. Is the staging environment back up?")
eq("serial commas and the list colon",
   raw: "we need three things from the vendor the sandbox access the API docs and a support contact",
   llm: "We need three things from the vendor: the sandbox access, the API docs, and a support contact.",
   "We need three things from the vendor: the sandbox access, the API docs, and a support contact.")
eq("the one comma that failed A3",
   raw: "did you get a chance to look at the PR I pushed last night no rush just checking",
   llm: "Did you get a chance to look at the PR I pushed last night? No rush, just checking.",
   "Did you get a chance to look at the PR I pushed last night? No rush, just checking.")
// The seam the rule exists for — a full stop before a lowercase word.
eq("a stranded full stop is still repaired",
   raw: "is it better to commit now or wait until tomorrow",
   llm: "Is It better to commit now. or wait until tomorrow?",
   "Is it better to commit now or wait until tomorrow?")

// Frozen in review/LEDGER.md, "C-group intensity resolved". These are not
// ours to adjust.
print("\nscoped self-correction — the frozen C-group")
eq("C1 resolves aggressively, reason dropped",
   raw: "let's go there on Tuesday wait no Tuesday I am busy maybe let's try Thursday",
   llm: "Let's go there on Thursday.", "Let's go there on Thursday.")
eq("C2 resolves minimally, only the wrong number dies",
   raw: "tell finance to release forty thousand uh sorry forty five thousand for the vendor invoice",
   llm: "Tell finance to release forty five thousand for the vendor invoice.",
   "Tell Finance to release 45,000 for the vendor invoice.")
eq("C3 resolves and keeps the reason",
   raw: "ask Rohan to review it no wait I mean Rohit Rohan's on leave",
   llm: "Ask Rohit to review it. Rohan is on leave.",
   "Ask Rohit to review it. Rohan is on leave.")
eq("C4 CONTROL two real days, no marker, never fires",
   raw: "move Tuesday's meeting to Thursday", llm: "Move Tuesday's meeting to Thursday.",
   "Move Tuesday's meeting to Thursday.")
eq("C5 CONTROL abandoned idea, no successor, never fires",
   raw: "we could also loop in the design team actually no forget it let's keep this small",
   llm: "We could also loop in the design team. Actually, no, forget it, let's keep this small.",
   "We could also loop in the design team. Actually, no, forget it, let's keep this small.")

// The contract everywhere outside the waiver is unchanged. These are the
// cases that would go quiet first if the span ever widened.
print("\nnever-lose-a-word, everywhere else")
eq("no marker means no waiver, even with a same-class pair",
   raw: "ask Rohan to review it Rohit is on leave", llm: "Ask Rohit to review it.",
   "Ask Rohan to review it Rohit is on leave.")
eq("an unrelated clause is still restored",
   raw: "the deploy went fine and the dashboard is slow", llm: "The deploy went fine.",
   "The deploy went fine and the dashboard is slow.")
eq("a marker with no successor drops nothing",
   raw: "we should ship it actually no forget it", llm: "We should ship it.",
   "We should ship it actually no forget it.")

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
