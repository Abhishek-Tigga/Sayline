import Foundation

/// Controls how the AI cleanup pass treats a raw transcript before insertion.
enum DictationStyle: String, CaseIterable, Equatable, Hashable, Codable {
    case verbatim
    case clean
    case concise

    var displayName: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .concise: return "Concise"
        }
    }

    /// nil means "skip the cleanup LLM call entirely, use the raw transcript as-is".
    var systemPrompt: String? {
        switch self {
        case .verbatim:
            return nil
        case .clean:
            return """
            You clean up raw speech-to-text transcripts for dictation. Remove filler \
            words (um, uh, like, you know), fix grammar, punctuation, and \
            capitalization, and remove false starts or repeated words. Preserve the \
            speaker's meaning, tone, and intent exactly — do not add information, do \
            not answer questions, do not add commentary, do not shorten or restructure \
            sentences beyond removing disfluencies. Output ONLY the cleaned text, \
            nothing else.
            """
        case .concise:
            return """
            You rewrite raw speech-to-text dictation to be more concise. Remove \
            filler words, false starts, hedging phrases (I think, kind of, probably, \
            sort of), and unnecessary or redundant words and phrases. Merge run-on \
            sentences. Tighten the wording while preserving the speaker's core \
            meaning and intent exactly — do not add information, do not answer \
            questions, do not add commentary. Output ONLY the rewritten text, \
            nothing else.
            """
        }
    }

    func next() -> DictationStyle {
        let all = Self.allCases
        let currentIndex = all.firstIndex(of: self) ?? 0
        return all[(currentIndex + 1) % all.count]
    }
}
