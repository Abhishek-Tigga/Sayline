// Checks for the vocabulary-bias ladder (DESIGN-vocabulary-biasing.md).
//
//   swiftc -o /tmp/chk Sources/Sayline/VocabularyBias.swift \
//     eval/bias-checks/main.swift && /tmp/chk
//
// Pure logic only: the known-word filter is injected, so these run
// without the system dictionary, Contacts, or AppKit.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

// A tiny stand-in dictionary. "figma" and "sayline" are deliberately
// absent — they are the words biasing exists for.
let known: Set<String> = ["notes", "music", "final", "cut", "pro", "safari",
                          "calendar", "the", "rose"]
let isKnown: (String) -> Bool = { known.contains($0) }

func entries(myWords: [String] = [], contacts: [String] = [],
             apps: [String] = [], history: String = "") -> [String] {
    VocabularyBias.assemble(myWords: myWords, contactFirstNames: contacts,
                            appNames: apps, historyText: history,
                            isKnownWord: isKnown)
}

// MARK: Ladder order — box, then contacts, then apps (decision 2)
do {
    let out = entries(myWords: ["Designwell"], contacts: ["Priya"],
                      apps: ["Figma"])
    check(out == ["Designwell", "Priya", "Figma"],
          "ladder order: my words, contacts, apps — got \(out)")
}

// MARK: Known-word filter applies to apps only (decision 2)
do {
    let out = entries(contacts: ["Rose"],
                      apps: ["Notes", "Final Cut Pro", "Figma", "Safari"])
    check(out.contains("Rose"),
          "a contact named a dictionary word is kept — names are names")
    check(!out.contains("Notes") && !out.contains("Final Cut Pro")
          && !out.contains("Safari"),
          "apps made of dictionary words are skipped")
    check(out.contains("Figma"), "unusual app names survive the filter")
}

// MARK: History ranks contacts, ties keep original order (decision 3)
do {
    let out = entries(contacts: ["Aarav", "Zoya", "Priya"],
                      history: "ask Priya about the deck, Priya said yes, and Zoya agreed")
    check(out == ["Priya", "Zoya", "Aarav"],
          "history ranking: mentioned-most first, unmentioned keep order — got \(out)")
}

// MARK: History never ADDS a word (decisions 1 and 3)
do {
    let out = entries(contacts: ["Priya"],
                      history: "lunch with Kunal about Designwell")
    check(!out.contains("Kunal") && !out.contains("Designwell"),
          "words in history but in no source are never admitted")
}

// MARK: Deduplication across sources
do {
    let out = entries(myWords: ["Priya"], contacts: ["priya"], apps: ["PRIYA"])
    check(out == ["Priya"],
          "one word in three sources enters once, first spelling wins — got \(out)")
}

// MARK: Budget cap — cut from the end, box always survives
do {
    let manyContacts = (1...400).map { "Contactname\($0)" }
    let out = entries(myWords: ["Sayline"], contacts: manyContacts,
                      apps: ["Figma"])
    check(out.first == "Sayline", "box word survives a 400-contact flood")
    let glossary = VocabularyBias.glossary(
        myWords: ["Sayline"], contactFirstNames: manyContacts,
        appNames: ["Figma"], historyText: "", isKnownWord: isKnown)!
    check(VocabularyBias.estimateTokens(glossary) <= VocabularyBias.tokenBudget,
          "assembled glossary stays inside the token budget "
          + "(~\(VocabularyBias.estimateTokens(glossary)) of \(VocabularyBias.tokenBudget))")
    check(out.count < manyContacts.count,
          "overflow is actually cut, not squeezed in")
}

// MARK: Template and emptiness (decision 7, fail open)
do {
    check(VocabularyBias.glossary(myWords: [], contactFirstNames: [],
                                  appNames: [], historyText: "",
                                  isKnownWord: isKnown) == nil,
          "no sources -> nil, so no prompt field is sent at all")
    let glossary = VocabularyBias.glossary(myWords: ["Sayline"],
                                           contactFirstNames: [], appNames: [],
                                           historyText: "", isKnownWord: isKnown)
    check(glossary == "Glossary: Sayline",
          "the one fixed template — got \(glossary ?? "nil")")
    check(entries(myWords: [" ", "", "  Designwell  "]) == ["Designwell"],
          "blank box entries dropped, whitespace trimmed")
}

print(failures == 0 ? "PASS — vocabulary bias ladder holds"
                    : "FAIL — \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
