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

// MARK: Echo guard — Whisper reciting the hint list back (2026-08-14 live)
do {
    // The glossary as it was the night the echo opened seven apps.
    let live = ["ChatGPT", "DetailsPro", "Display Pilot 2", "Figma",
                "Google Chrome", "HeyClicky", "LogiPluginService",
                "Microsoft Excel", "Microsoft Word", "Muesli", "Numbers",
                "OneDrive", "Pages", "RemotePlay", "Sticky Notepad",
                "VoiceOS", "WhatsApp", "Wispr Flow", "Xcode", "cmux",
                "iMovie", "logioptionsplus"]
    func echo(_ t: String) -> Bool {
        VocabularyBias.looksLikeEcho(transcript: t, entries: live)
    }

    // Both real echoes from the log, verbatim.
    check(echo("Glossary, LogiPluginService, Microsoft Word, Muesli, Numbers, OneDrive, Pages, RemotePlay,"),
          "the seven-app echo trips (consecutive run)")
    check(echo("Glossary, Figma, Glossary, LogiP, Vodka, Zimbab, Glossary."),
          "the garbled vodka.com echo trips (repeated template word)")

    // Real speech that must never trip.
    check(!echo("open Figma and WhatsApp"),
          "naming two apps is a command, not an echo")
    check(!echo("open Microsoft Excel and Microsoft Word"),
          "two list-neighbors stay under the run threshold")
    check(!echo("Figma, WhatsApp and Xcode please"),
          "three non-neighbor entries in list order do not trip")
    check(!echo("add a glossary section to the Figma doc"),
          "one mention of the word glossary in real speech survives")
    check(!echo("what does glossary mean"),
          "the word glossary with no entries survives")
    check(!echo(""), "empty transcript is not an echo")
    check(!VocabularyBias.looksLikeEcho(transcript: "Glossary, Figma, Glossary",
                                        entries: []),
          "no glossary sent means nothing can be an echo of it")

    // The failure that motivated the no-loudness-gate design: these
    // arrived with peaks of 1.0 and 0.08 — the guard must not care.
    check(echo("Glossary, LogiPluginService, Microsoft Word, Muesli, Numbers, OneDrive, Pages, RemotePlay,"),
          "structural detection needs no audio signal (same case, restated)")
}



// MARK: Echo prefix stripping (live leak on real speech, 2026-08-18)
check(VocabularyBias.strippingEchoPrefix("Glossary, Wihra, Pabir, just want to inform you")
        == "Wihra, Pabir, just want to inform you",
      "the literal template label is stripped off the front")
check(VocabularyBias.strippingEchoPrefix("Glossary: Figma, WhatsApp") == "Figma, WhatsApp",
      "colon form strips too")
check(VocabularyBias.strippingEchoPrefix("A glossary, in general, is a list")
        == "A glossary, in general, is a list",
      "mid-sentence use of the word is untouched")
check(VocabularyBias.strippingEchoPrefix("Glossary means a list of terms")
        == "Glossary means a list of terms",
      "opening the sentence WITH the word (no comma) is real speech and survives")

print(failures == 0 ? "PASS — vocabulary bias ladder holds"
                    : "FAIL — \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
