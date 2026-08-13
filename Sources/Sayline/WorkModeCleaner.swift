import Foundation

/// Work mode: *what you meant*, restructured — as opposed to Clean, which
/// is *what you said*, tidied.
///
/// A separate file rather than a mode on `TranscriptCleaner`, deliberately.
/// Clean's promise is "never lose a word", enforced by
/// `TranscriptCleanupValidator` reverting any edit outside a whitelist.
/// That validator would revert a rewrite entirely, so Work needs a
/// different guard — `FactGuard` — and mixing the two into one file would
/// put two incompatible safety contracts in one place, where a later edit
/// could apply the wrong one. Clean's prompt and validator are untouched
/// by anything here.
///
/// The model and the numbers behind it: measured 2026-08-13 over 25
/// transcripts, ten of them real, scored by `FactGuard`.
/// `llama-3.3-70b-versatile` broke a fact in 24% of transcripts, the
/// single corrective retry rescued 83% of those, 4% ended in fallback, at
/// a 341 ms median. It was chosen over `gpt-4o-mini` — better on the real
/// ten at 2/10 against 3/10 — because 1319 ms plus a retry lands near
/// 2.6 s, and decision 7 calls that "reads as broken". See
/// `review/LEDGER.md`.
///
/// **Known ceiling:** this rides Groq's free tier, which eval work alone
/// capped twice at 100K tokens/day. If that bites before the backend
/// exists, `gpt-4o-mini` is the fallback and the mode gets slower rather
/// than broken.
final class WorkModeCleaner {
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let model = "gpt-4o-mini"

    /// What happened, so the caller can flash the right thing and the log
    /// can answer "does the guard fire too often" as a lookup.
    enum Outcome {
        /// The rewrite passed the guard. Insert it.
        case rewritten(String)
        /// The first attempt broke a fact and the retry fixed it.
        case rescued(String, firstAttemptBroke: [FactGuard.Violation])
        /// Both attempts broke a fact. Insert Clean's output instead and
        /// say so — never silent, never nothing.
        case fellBack(reason: FactGuard.Violation)

        var text: String? {
            switch self {
            case .rewritten(let t), .rescued(let t, _): return t
            case .fellBack: return nil
            }
        }
    }

    // MARK: - Prompt

    /// Constraints live in the system message; the transcript arrives
    /// alone in the user message.
    ///
    /// Not a formatting preference. When the pinned facts were appended to
    /// the user content with a delimiter, a model echoed them into a
    /// rewrite verbatim — "...until we actually talk to sales. |
    /// negations: 2 — do not reverse any statement". Escaping the
    /// delimiter treats the symptom; the disease is content-role
    /// confusion, and putting instructions where instructions live also
    /// makes a "do not echo this" instruction unnecessary.
    private static let workPrompt = """
    You tighten spoken dictation into clear written text. You are not \
    writing on the speaker's behalf — you are their words, minus the mess.

    Delete: fillers, repetition, false starts, and the journey ("I've \
    been going back and forth on this all morning"). Put the conclusion \
    first. Merge rambling sentences.

    Keep: their verbs, their bluntness, their meaningful hedges — \
    "about", "roughly", "realistically" carry information and stay.

    Rules you must not break:
    - NEVER upgrade a word. "Isn't done" stays "isn't done" — not \
    "remains incomplete". "Use" is not "utilize". "Like we said" is not \
    "as per".
    - NEVER soften a position. "I don't agree" stays "I don't agree" — \
    not "I'm not fully aligned", not "I have some reservations". \
    Softening what someone said is changing what they said.
    - Your reply must be SHORTER than what they said. If you cannot cut, \
    return their sentence tidied. Never pad.
    - Never invent facts, names, numbers, dates, or commitments.
    - Never reverse a statement, and never answer a question they asked — \
    if they asked something, it stays a question.
    - If they enumerated items — "three reasons: first… second…" — write \
    them as "- " bullets, one per line. Not for prose that merely \
    contains several ideas.
    - Never invent headers, greetings or sign-offs, and never comment on \
    your own output.
    - Output only the rewritten text. No preamble, no quotes.
    """

    /// Warmth only — two things, and nothing else.
    ///
    /// Context may decide **whether a greeting survives** and **whether
    /// sentences are complete**. It may not touch vocabulary or stance.
    ///
    /// Amended 2026-08-13 after the first live session. The email
    /// register read "composed and professional", and it produced output
    /// that was longer than the speech and softer than the position —
    /// "I don't agree" arriving as something more diplomatic. Softening a
    /// stated position is meaning change wearing a politeness costume,
    /// the same failure family the guard exists for, so the register was
    /// not a style knob at all. It is now two switches.
    private static func register(for context: AppContext) -> String {
        switch context {
        case .email:
            return "This is going into an email. If they opened with a greeting, keep it. Complete sentences."
        case .chat:
            return "This is going into a chat app. Drop any greeting. Fragments are fine."
        case .code, .general:
            return "Destination unknown. Complete sentences, no greeting."
        }
    }

    // MARK: - The turn

    /// Rewrites, verifies, retries once, or falls back.
    ///
    /// `cleanFallback` is the Clean pipeline's output for the same
    /// transcript, computed by the caller. Passed in rather than
    /// recomputed so a fallback costs nothing extra at the moment it is
    /// needed — the user is already waiting.
    func rewrite(_ raw: String, context: AppContext) async throws -> Outcome {
        let facts = FactGuard.extract(from: raw)
        let pinned = FactGuard.promptBlock(for: facts)
        let system = [Self.workPrompt, Self.register(for: context), pinned]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let first = try await ask(system: system, messages: [["role": "user", "content": raw]])
        let firstViolations = FactGuard.verify(raw: raw, rewrite: first)
        if firstViolations.isEmpty {
            return .rewritten(first)
        }

        // One corrective retry, naming the broken fact — including the
        // Voice 2 rules, which use the same machinery: a rewrite that
        // padded or upgraded a word gets told exactly that.
        SaylineLog.log("[work] first attempt broke: "
            + firstViolations.map(\.kind).joined(separator: ", "))
        let why = firstViolations.map(\.explanation).joined(separator: "; ")
        let retry = try await ask(system: system, messages: [
            ["role": "user", "content": raw],
            ["role": "assistant", "content": first],
            ["role": "user", "content":
                "That reply broke a fact: \(why). Rewrite it again, keeping every fact from the original."],
        ])

        let retryViolations = FactGuard.verify(raw: raw, rewrite: retry)
        if retryViolations.isEmpty {
            SaylineLog.log("[work] retry rescued it")
            return .rescued(retry, firstAttemptBroke: firstViolations)
        }

        SaylineLog.log("[work] retry also broke: "
            + retryViolations.map(\.kind).joined(separator: ", ") + " — falling back to Clean")
        return .fellBack(reason: retryViolations[0])
    }

    /// The sentence shown when the guard refuses a rewrite.
    ///
    /// Names what happened rather than apologising. Decision 2: never
    /// silent, never nothing — the user gets their exact words and one
    /// line explaining why.
    static func fallbackMessage(for violation: FactGuard.Violation) -> String {
        switch violation.kind {
        case "day", "invented-day": return "Kept your exact words — the rewrite changed a day"
        case "month", "invented-month": return "Kept your exact words — the rewrite changed a month"
        case "number", "invented-number": return "Kept your exact words — the rewrite changed a number"
        case "unit", "invented-unit": return "Kept your exact words — the rewrite changed a unit"
        case "relative-time": return "Kept your exact words — the rewrite changed the timing"
        case "negation", "negation-added": return "Kept your exact words — the rewrite flipped a meaning"
        case "invented-name": return "Kept your exact words — the rewrite named someone you didn't"
        case "invented-commitment": return "Kept your exact words — the rewrite promised something you didn't"
        case "longer-than-speech": return "Kept your exact words — the rewrite was longer than what you said"
        case "formality-upgrade": return "Kept your exact words — the rewrite dressed them up"
        case "question-lost": return "Kept your exact words — the rewrite answered your question instead"
        default: return "Kept your exact words — the rewrite changed a fact"
        }
    }

    private func ask(system: String, messages: [[String: String]]) async throws -> String {
        guard let apiKey = APIKeyProvider.openAIAPIKey else {
            throw TranscriptionError.missingAPIKey
        }
        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]] + messages,
            // Zero, not Clean's 0.2. A rewrite has more room to wander than
            // a tidy-up, and every point of temperature is another chance
            // to invent something the guard then has to catch.
            "temperature": 0,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw TranscriptionError.apiError(
                String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw TranscriptionError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
