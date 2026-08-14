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
/// **The model changed when Voice 2 landed, and the reason is worth
/// keeping.** Measured 2026-08-13 over 31 transcripts — ten real, six
/// Voice-2 style cases — scored by `FactGuard`:
///
/// ```
///                          broke   rescued   fallback   median
/// llama-3.3-70b-versatile   24%       0%       24%      291 ms
/// gpt-4o-mini               23%      43%       13%      922 ms
/// gpt-4.1-mini              26%      75%        6%     2244 ms
/// ```
///
/// Under the earlier free-rewrite prompt the 70B rescued **83%** of its
/// own violations and fell back 4% of the time. Voice 2 adds a hard
/// length ceiling, and told "cut, don't pad" the 70B rescued **0 of 7** —
/// a quarter of work dictations would silently deliver Clean instead. The
/// fastest model stopped being the best one.
///
/// `gpt-4o-mini` costs 631 ms more and halves the fallback rate; with
/// Clean running concurrently the user waits about a second, against the
/// ~2 s decision 7 allows. `gpt-4.1-mini` is better again on fallback and
/// blows the budget at 2.2 s.
///
/// Incidentally this leaves Groq's free tier, the standing operational
/// risk — the 8B baseline aborted that very run at 13 of 31 calls.
///
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
    contains several ideas. ALWAYS keep the line that introduces the \
    list, so the reader knows what the list is of. "So this is how we \
    should do it. First… second…" becomes "How we should do it:" and \
    then the bullets — never bullets on their own.
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
    /// How long a rewrite may take before Clean is used instead.
    ///
    /// Measured 2026-08-14 over nine live work holds: median rewrite 3.05s,
    /// but three holds took 10.6–11.1s — OpenAI's tail, unrelated to input
    /// length (an 8s/20-word dictation took 10.8s while a 38s/67-word one
    /// took 3.5s). Nothing in this code makes that faster, so the fix is to
    /// stop waiting for it. Four seconds is above the p95 of the healthy
    /// runs and far below the tail.
    ///
    /// This costs nothing when it fires: Clean is already in flight and
    /// almost certainly finished, so the user gets tidied text instead of
    /// an eleven-second stare.
    static let timeout: Duration = .seconds(4)

    func rewrite(_ raw: String, context: AppContext) async throws -> Outcome {
        let facts = FactGuard.extract(from: raw)
        let pinned = FactGuard.promptBlock(for: facts)
        let system = [Self.workPrompt, Self.register(for: context), pinned]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let first = try await withTimeout(Self.timeout) {
            try await self.ask(system: system, messages: [["role": "user", "content": raw]])
        }
        let firstViolations = FactGuard.verify(raw: raw, rewrite: first, context: context)
        if firstViolations.isEmpty {
            return .rewritten(first)
        }

        // One corrective retry, naming the broken fact — including the
        // Voice 2 rules, which use the same machinery: a rewrite that
        // padded or upgraded a word gets told exactly that.
        SaylineLog.log("[work] first attempt broke: "
            + firstViolations.map(\.kind).joined(separator: ", "))
        let why = firstViolations.map(\.explanation).joined(separator: "; ")
        let retry = try await withTimeout(Self.timeout) {
            try await self.ask(system: system, messages: [
            ["role": "user", "content": raw],
            ["role": "assistant", "content": first],
            ["role": "user", "content":
                "That reply broke a fact: \(why). Rewrite it again, keeping every fact from the original."],
            ])
        }

        let retryViolations = FactGuard.verify(raw: raw, rewrite: retry, context: context)
        if retryViolations.isEmpty {
            SaylineLog.log("[work] retry rescued it")
            return .rescued(retry, firstAttemptBroke: firstViolations)
        }

        SaylineLog.log("[work] retry also broke: "
            + retryViolations.map(\.kind).joined(separator: ", ") + " — falling back to Clean")
        return .fellBack(reason: retryViolations[0])
    }

    /// Shown when the rewrite never came back at all — no network, no
    /// OpenAI key, a 500 — as opposed to coming back and being refused.
    ///
    /// A separate sentence because it is a separate event, and the user can
    /// act on this one: the others say the rewrite was wrong, this one says
    /// there was no rewrite. Same contract as decision 2 either way — never
    /// silent, never nothing.
    static let unavailableMessage = "Used the tidied version — the rewrite didn't come back"

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

    /// Races the work against a sleep. Whichever finishes first wins and
    /// the other is cancelled.
    ///
    /// `TaskGroup` rather than a detached timer so cancellation actually
    /// propagates into URLSession — a timeout that leaves the request
    /// running still holds the connection and still costs the token.
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimedOut()
            }
            guard let winner = try await group.next() else { throw TimedOut() }
            group.cancelAll()
            return winner
        }
    }

    struct TimedOut: Error {}

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
