import Foundation

/// Voice commands, detected on the raw transcript before cleanup/context
/// processing. Deliberately whole-utterance-only — a dictation counts as
/// a command only if the ENTIRE recording is just the command phrase,
/// never as a substring inside a longer sentence. "Scratch that idea,
/// let's go with plan B" must never trigger anything; only holding the
/// hotkey and saying exactly "scratch that" should.
enum VoiceCommand {
    case scratchThat
    case newParagraph
    case newLine

    static func detect(in rawText: String) -> VoiceCommand? {
        let normalized = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))

        switch normalized {
        case "scratch that", "undo that", "undo":
            return .scratchThat
        case "new paragraph":
            return .newParagraph
        case "new line":
            return .newLine
        default:
            return nil
        }
    }
}
