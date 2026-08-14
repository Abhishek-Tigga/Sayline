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

print(failures == 0 ? "PASS — hallucination guards hold"
                    : "FAIL — \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
