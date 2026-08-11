import Foundation

/// Voice commands, detected on the raw transcript before cleanup/context
/// processing. Deliberately whole-utterance-only — a dictation counts as
/// a command only if the ENTIRE recording is close to just the command
/// phrase, never as a substring inside a longer sentence. "Scratch that
/// idea, let's go with plan B" must never trigger anything; only holding
/// the hotkey and saying essentially just "scratch that" should.
///
/// Matching combines two checks, not similarity alone — found live that
/// similarity by itself isn't enough: "scratch that idea" scored 0.94
/// against "scratch that" (Jaro-Winkler weighs shared prefixes heavily,
/// so one extra trailing word barely dents the score), which would have
/// wrongly triggered the command on real dictated content. A word-count
/// match is required alongside the similarity threshold — tolerates a
/// misheard *word* (transcription noise), never an *extra* word.
enum VoiceCommand {
    case scratchThat
    case newParagraph
    case newLine

    private static let matchThreshold = 0.90

    private static let phrases: [(String, VoiceCommand)] = [
        ("scratch that", .scratchThat),
        ("undo that", .scratchThat),
        ("undo", .scratchThat),
        ("new paragraph", .newParagraph),
        ("new line", .newLine),
    ]

    static func detect(in rawText: String) -> VoiceCommand? {
        let normalized = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        let normalizedWordCount = wordCount(normalized)

        var best: (command: VoiceCommand, phrase: String, score: Double)?
        for (phrase, command) in phrases {
            guard normalizedWordCount == wordCount(phrase) else { continue }
            let score = JaroWinkler.similarity(normalized, phrase)
            if score >= matchThreshold, best == nil || score > best!.score {
                best = (command, phrase, score)
            }
        }

        if let best {
            let scoreString = String(format: "%.2f", best.score)
            SaylineLog.log("voice command matched \"\(normalized)\" ~ \"\(best.phrase)\" (similarity: \(scoreString)) -> \(best.command)")
        }
        return best?.command
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(separator: " ").count
    }
}
