// Checks for WhisperHallucination — the filler-phrase filter and the
// repetition-loop detector.
//
//   swiftc -o /tmp/chk Sources/Sayline/WhisperHallucination.swift \
//     eval/hallucination-checks/main.swift && /tmp/chk

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

// MARK: Repetition loops (live gibberish, 2026-08-14, any loudness)
check(WhisperHallucination.hasRepetitionLoop(
        "Ai Aiki Udine, Dhe Dhe Tlaio, Tate Seri Bajol, Tate Seri Bajol, Tate Seri Bajol"),
      "the live YouTube-search gibberish trips")
check(WhisperHallucination.isLikelyHallucinated(
        "Tate Seri Bajol, Tate Seri Bajol, Tate Seri Bajol", audioPeak: 1.0),
      "a loop is discarded even at full loudness")

check(!WhisperHallucination.hasRepetitionLoop("no no no no no no"),
      "single-word runs are real speech, never a loop")
check(!WhisperHallucination.hasRepetitionLoop("I said no. I said no."),
      "two repeats stay under the threshold")
check(!WhisperHallucination.hasRepetitionLoop(
        "move the meeting to Thursday and tell the team about the change"),
      "an ordinary sentence does not trip")
check(!WhisperHallucination.hasRepetitionLoop("very very good, very very good"),
      "a doubled pair is emphasis, not a loop")
check(WhisperHallucination.hasRepetitionLoop(
        "I said no. I said no. I said no."),
      "three identical multi-word repeats trip (accepted residual, visible discard)")

// MARK: The original filler filter still behaves
check(WhisperHallucination.isLikelyHallucinated("Thank you.", audioPeak: 0.01),
      "quiet 'Thank you.' is the known filler")
check(!WhisperHallucination.isLikelyHallucinated("Thank you.", audioPeak: 0.15),
      "a spoken 'Thank you.' at real loudness survives")
check(!WhisperHallucination.isLikelyHallucinated(
        "the deploy went fine no errors", audioPeak: 0.01),
      "quiet but substantive speech survives")

// MARK: Made-up word triples (live leak, 2026-08-15, typed into a document)
let smallDict: Set<String> = ["no", "very", "good", "i", "said", "move", "the",
                              "meeting", "to", "thursday", "ask", "about"]
let knows: (String) -> Bool = { smallDict.contains($0) }

check(WhisperHallucination.hasRepetitionLoop(
        "NAR-Lex Kajraa Likki Hedesh Gupta Hiver Likki Hedesh Gugge Gugge Gugge Bungge",
        isKnownWord: knows),
      "the live typed-gibberish leak trips (made-up word tripled)")
check(!WhisperHallucination.hasRepetitionLoop("no no no no no no", isKnownWord: knows),
      "a real word tripled is still speech")
check(!WhisperHallucination.hasRepetitionLoop(
        "ask Hirdesh about Razorpay and the meeting", isKnownWord: knows),
      "unknown words without repetition are names, not junk")
check(!WhisperHallucination.hasRepetitionLoop(
        "Gugge Gugge Gugge Bungge Hidesh Gugge"),
      "no dictionary supplied -> the made-up-word rule stays disarmed")

// MARK: Decoder confidence (verbose_json segments)
typealias Stats = WhisperHallucination.DecodeStats
let junkSilence = Stats(avgLogprob: -1.4, noSpeechProb: 0.9, compressionRatio: 1.2)
let junkLoop = Stats(avgLogprob: -0.4, noSpeechProb: 0.1, compressionRatio: 3.1)
let good = Stats(avgLogprob: -0.25, noSpeechProb: 0.02, compressionRatio: 1.5)
let weakTail = Stats(avgLogprob: -1.2, noSpeechProb: 0.7, compressionRatio: 1.3)

check(WhisperHallucination.isLowConfidence([junkSilence]),
      "doubted-speech + low confidence discards")
check(WhisperHallucination.isLowConfidence([junkLoop]),
      "loop-grade compression discards")
check(WhisperHallucination.isLowConfidence([junkSilence, junkLoop]),
      "all segments junk discards")
check(!WhisperHallucination.isLowConfidence([good, weakTail]),
      "one solid segment saves the transcript — all-or-nothing by design")
check(!WhisperHallucination.isLowConfidence([good]),
      "an ordinary confident segment passes")
check(!WhisperHallucination.isLowConfidence([]),
      "no stats -> accept, the guard fails open")
check(!WhisperHallucination.isLowConfidence(
        [Stats(avgLogprob: -1.4, noSpeechProb: 0.2, compressionRatio: 1.2)]),
      "low confidence alone (clear speech present) is not junk — quiet mumbling stays")

print(failures == 0 ? "PASS — hallucination guards hold"
                    : "FAIL — \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
