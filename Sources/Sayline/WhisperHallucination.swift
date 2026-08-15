import Foundation

/// Catches the short stock phrases Whisper invents when it is handed
/// near-silence. Confirmed live 2026-08-09: a single session produced ten
/// of these — mostly "." and "Thank you." — each one pasted into whatever
/// the user was typing in.
///
/// The filter deliberately needs *two* signals, not one.
///
/// Filtering on the phrase alone would throw away a genuine "thank you",
/// which is a normal thing to dictate. Filtering on loudness alone does
/// not work either: the measured peaks overlap. From that same session —
///
///     0.013  "Thank you."      <- invented
///     0.030  "Oh Oh, do do do I have a lead on it? I mean"
///     0.032  "There will be multiple applications"
///     0.039  "Estabulation or backlog patent IP or product entry."
///     0.044  "."               <- invented
///
/// — quiet but real speech sits inside the same band as the junk, so any
/// loudness cutoff high enough to catch the junk also discards real
/// dictation. That mistake was already made once here, with a cutoff that
/// silently ate 6, 8 and 11 second recordings.
///
/// Together the two signals separate cleanly. A real "thank you" is spoken
/// at normal volume and registers around 0.10–0.18; an invented one comes
/// from audio that never rose above ~0.05. So the phrase list stays tiny
/// and exact, and it only applies when the audio was quiet.
enum WhisperHallucination {
    /// Only phrases seen produced from actual silence, or widely reported
    /// as Whisper artefacts (they come from its training data — subtitle
    /// tracks are full of sign-offs). Kept deliberately short: every entry
    /// is something a person might really say, so each one is a small risk
    /// that only the loudness check makes safe.
    private static let phrases: Set<String> = [
        "",
        ".",
        "you",
        "bye",
        "thank you",
        "thanks",
        "thank you.",
        "thanks for watching",
        "thanks for watching!",
        "thank you for watching",
        "please subscribe",
        "subtitles by the amara.org community",
    ]

    /// Above this, treat the audio as genuinely spoken and never filter,
    /// no matter what the words are. Sits above the highest junk peak
    /// observed (0.044) and well below normal speech (0.098+).
    static let spokenPeakThreshold: Float = 0.06

    /// True when this looks like something Whisper made up rather than
    /// something the user said.
    static func isLikelyHallucinated(_ transcript: String, audioPeak: Float,
                                     isKnownWord: (String) -> Bool = { _ in true }) -> Bool {
        // Checked before the loudness gate, deliberately: the repetition
        // loop ("Tate Seri Bajol, Tate Seri Bajol, Tate Seri Bajol" —
        // live, 2026-08-14, routed to a YouTube search) arrives from
        // audio of any loudness, and even if the hold contained real
        // speech, a looping transcript is certainly not what was said.
        // Discarding it visibly beats typing or executing it.
        if hasRepetitionLoop(transcript, isKnownWord: isKnownWord) { return true }

        // Loud enough to be real speech — believe the transcript whatever
        // it says. This is what protects a genuine "thank you".
        guard audioPeak < spokenPeakThreshold else { return false }

        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,… "))

        // Anything with real substance is left alone. The artefacts are all
        // very short, so length alone rules out most false positives before
        // the list is even consulted.
        guard normalized.count <= 40 else { return false }

        return phrases.contains(normalized)
            || phrases.contains(transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Whisper's own per-segment confidence, from `verbose_json`.
    ///
    /// Requested since 2026-08-15, when 8.5 s of background noise at
    /// peak 0.33 transcribed as gibberish threaded with garbled
    /// glossary names ("Hedesh Gupta", "RZP") and typed itself into a
    /// document. Every structural guard passed it: not an exact echo,
    /// no 3× multi-word loop, too loud for the filler filter. The
    /// decoder, meanwhile, knew — these three numbers are what Whisper
    /// itself uses to reject its own output; we had just never asked.
    struct DecodeStats {
        let avgLogprob: Double
        let noSpeechProb: Double
        let compressionRatio: Double

        /// Whisper's own decode-fallback rules, verbatim: a segment is
        /// junk when the decoder both doubts speech was present AND had
        /// low confidence in what it wrote, or when the text compresses
        /// like a repetition loop.
        var isJunk: Bool {
            (noSpeechProb > 0.6 && avgLogprob < -1.0) || compressionRatio > 2.4
        }
    }

    /// True when EVERY segment is junk — the whole transcript is the
    /// decoder guessing. Deliberately all-or-nothing: a real dictation
    /// with one weak segment (a trailing breath) must survive, so
    /// partial junk passes and stays a known residual. Empty stats
    /// accept — fail open when the API didn't send them.
    static func isLowConfidence(_ stats: [DecodeStats]) -> Bool {
        guard !stats.isEmpty else { return false }
        return stats.allSatisfy(\.isJunk)
    }

    /// The decoder stuck in a loop: one multi-word phrase, immediately
    /// repeated three or more times. A known Whisper failure shape.
    ///
    /// Multi-word only, on purpose. Single-word runs are real speech —
    /// "no no no", "very very good" — and stay untouched however long.
    /// A person *can* deliberately dictate "I said no. I said no. I said
    /// no." and would lose it here; that residual risk is accepted
    /// because the discard is visible ("Didn't catch that"), while a
    /// looping transcript typed into a document — or executed as an
    /// agent command — is not.
    static func hasRepetitionLoop(_ transcript: String,
                                  isKnownWord: (String) -> Bool = { _ in true }) -> Bool {
        let words = transcript.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard words.count >= 6 else { return false }

        // A single *made-up* word repeated three times ("Gugge Gugge
        // Gugge" — live 2026-08-15, typed into a document inside a
        // gibberish dictation). Real speech triples real words — "no no
        // no" stays exempt because "no" is in the dictionary; a word in
        // neither the dictionary nor anywhere else, thrice in a row, is
        // the decoder stuttering. Length ≥ 4 keeps interjections
        // ("na na na") out of reach. Callers without a dictionary keep
        // the old behavior — the default closure knows every word.
        if words.count >= 3 {
            for i in 0...(words.count - 3) {
                let w = words[i]
                if w.count >= 4, words[i + 1] == w, words[i + 2] == w,
                   !isKnownWord(w) {
                    return true
                }
            }
        }

        for size in 2...5 where size * 3 <= words.count {
            for start in 0...(words.count - size * 3) {
                let phrase = Array(words[start..<start + size])
                // A phrase of one repeated word ("no no") would make any
                // long single-word run count as a multi-word loop — the
                // exact false positive the multi-word rule exists to
                // avoid. Caught by the suite before it shipped.
                guard Set(phrase).count > 1 else { continue }
                if Array(words[start + size..<start + size * 2]) == phrase,
                   Array(words[start + size * 2..<start + size * 3]) == phrase {
                    return true
                }
            }
        }
        return false
    }
}
