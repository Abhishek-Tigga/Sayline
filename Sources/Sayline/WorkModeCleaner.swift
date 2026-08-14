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
/// **Superseded 2026-08-14: the model is now `gpt-4.1-mini`.** The 2.2 s
/// above was real and is no longer, so the reason it lost has gone:
///
/// ```
///                broke  rescued  fallback  median   taste  taste, no ceiling
/// gpt-4o-mini     10%      67%       3%    1087ms    69%          84%
/// gpt-4.1-mini    10%     100%       0%    1092ms    84%         100%
/// ```
///
/// Same violation rate, same latency to within noise, and it never falls
/// back — 4o-mini silently delivers Clean on 3% of work dictations, which
/// is the failure the user actually notices. `taste` is `taste_score.py`
/// over the 13 auto-runnable scripts from round 1.
///
/// It read 19% here in the Phase C bake-off two days earlier, and lost on
/// that. That number was the guard's, not the model's: `FactGuard` could
/// not carry a spoken number across a scale word, so "forty five
/// thousand" rewritten as "45,000" scored as a number both lost and
/// invented. Fixing the guard moved 4.1-mini from 19% to 10% and left
/// 4o-mini where it was.
///
/// Every violation now left in the 31 — for both models — is
/// `longer-than-speech`, which is the one rule the fifteen rewrites the
/// user accepted also break. See `review/LEDGER.md`.
///
final class WorkModeCleaner {
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let model = "gpt-4.1-mini"

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

    Delete: fillers ("um", "like", "you know"), repetition, false starts, \
    and the journey ("I've been going back and forth on this all \
    morning"). Merge rambling sentences.

    Keep — these are content, not mess:
    - The opener. "Heads up", "quick status on the migration", "hi \
    Nikhil", "just floating this back up", "quick correction on my last \
    mail". These tell the reader what they are about to read and why it \
    arrived. Deleting one leaves a message that starts mid-thought.
    - Their verbs, their bluntness, their meaningful hedges. "About", \
    "roughly", "realistically" carry information.
    - The social lubricant. "Sorry to ping you again", "I know you're \
    slammed" — one light apology, not three.
    - The closing line. "That's the summary", "that's where we are", \
    "let me know", a spoken sign-off ("thanks", "best, <their name>"). \
    The tail is content like the opener: never make the text shorter by \
    deleting how they ended it.

    Shape: if they counted their items ("first… second…", "one… two…"), \
    the whole output is an intro line then a numbered list, "1. ", "2. ", \
    one item per line, in the order they said them. This holds in email \
    too. Do NOT lift an item out to the front and do not repeat it. \
    Otherwise: two or three short paragraphs with a blank line between \
    them, never one dense block, conclusion or bad news first.

    Rules you must not break:
    - NEVER upgrade a word. "Isn't done" stays "isn't done", not \
    "remains incomplete". "Use" is not "utilize". "Like we said" is not \
    "as per". "Was really something" is not "was exceptional". "Whoever" \
    is never "whosoever".
    - NEVER soften a position. A no stays a no; pushback stays pushback. \
    "I don't agree" is not "I'm not fully aligned". "The March date isn't \
    going to happen" does not become "may face challenges".
    - You MAY round the delivery. "I'd rather" can become "I'd lean \
    towards"; an absolute can ease ("that never works" → "that usually \
    doesn't end well"). This is tone, and it stops at the position: what \
    they decided, refused or asserted is untouchable.
    - Never longer than what they said. Equal length is fine when there \
    is nothing to cut — return their sentence tidied rather than padding \
    it, and never buy room by deleting the opener.
    - Never invent facts, names, numbers, dates, or commitments.
    - Never reverse a statement, and never answer a question they asked — \
    if they asked something, it stays a question.
    - If they counted their items — "three reasons: first… second…", \
    "first thing… second thing…", "one… two… three…" — write them as a \
    numbered list: "1. ", "2. ", one per line. Their ordinals ARE \
    numbering; bullets would throw it away. Use "- " bullets only for \
    items listed without counting. ALWAYS keep the line that introduces \
    the list, so the reader knows what the list is of. "There are three \
    reasons. First… second…" becomes "There are three reasons:" and then \
    the numbered lines — never a list on its own.
    - No em-dashes. Use a comma, a full stop, or a new sentence.
    - Numbers inside a sentence read as words: "four hours", not "4 \
    hours". Leave figures alone when they are data: "70 percent", \
    "47,500", "11am".
    - Never invent headers, and never comment on your own output.
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
    private static func register(for context: AppContext, signOffName: String) -> String {
        switch context {
        case .email:
            // The shell, per the amendment taste round 1 argued for: every
            // ideal email the user wrote has a greeting and "Best, <name>".
            // Only added when a name is configured — the app never guesses
            // one, which is what decision 1 was actually protecting.
            let shell = signOffName.isEmpty ? "" : """

            Format it as an email: keep or add a greeting line ("Hi \(signOffName == "" ? "" : "")…"), \
            then the body in two or three short paragraphs, then sign off on its own line as:
            Best,
            \(signOffName)
            Use the recipient's name in the greeting only if they said it.
            """
            return "This is going into an email. If they opened with a greeting, keep it. "
                + "Complete sentences." + shell
        case .chat:
            return "This is going into a chat app. Drop any greeting. Fragments are fine."
        case .code, .general:
            return "Destination unknown. Complete sentences, no greeting."
        }
    }

    /// Three worked examples, shown to the model before the transcript.
    ///
    /// **These are the user's own writing** — three of the fifteen rewrites
    /// they pasted in taste round 1 as "what I actually wanted", copied
    /// character-for-character from `eval/work-mode/ideals-normalized.json`
    /// with one edit: em-dashes replaced, because an example teaches every
    /// tic it contains and the em-dash is banned two rules above.
    ///
    /// **Shipped on the user's blind verdict, against the scorer's.** The
    /// mechanical taste scorer rejected few-shots twice, most recently at
    /// eight points behind on its sendable proxy. A blind A/B over six
    /// fresh dictations — randomized assignment, key sealed until the
    /// verdicts were in — went 4–0 to this arm with two honest ties, and
    /// the user's reasons named real differences: the bare prompt deleted a
    /// spoken "Good morning everyone" (decapitation, taste round 1's
    /// failure #1) and lost a colon and a comma the examples carry. The
    /// bare arm also broke a fact the examples arm did not, promoting "I
    /// would like to hand it over" to "I will".
    ///
    /// Cost: +49% input tokens, and measured 195 ms FASTER in wall clock on
    /// the six (1778 ms vs 1973 ms median) — examples appear to shorten the
    /// model's search rather than lengthen it. See `review/LEDGER.md`, and
    /// the disclosed randomization defect there before treating 4–0 as six
    /// independent trials.
    ///
    /// One set for every context, exactly as tested. Splitting them by
    /// context would ship a configuration nothing measured.
    static let examples: [(spoken: String, written: String)] = [
        // E1 — the email shell, bad news in the first line.
        ("hi Nikhil, so um about the integration timeline, look I have to be straight with you, the March date isn't going to happen, we found a data issue on our side that needs maybe two more weeks, um the new realistic date is mid April, I know that's not what you wanted to hear, happy to get on a call this week if that helps",
         """
         Hi Nikhil,

         I wanted to be upfront about the integration timeline, the March date is no longer realistic. We found a data issue on our side that will likely take another two weeks to resolve.

         The new realistic target is mid-April. I know that's not what you were hoping to hear, and I'm happy to get on a call this week to discuss it if helpful.

         Best,
         Abhishek
         """),
        // T4 — chat register: the opener survives, the position stays theirs.
        ("so heads up, um the vendor sandbox went down this morning and their support says forty eight hours, which honestly kills our Thursday demo, I think we either fake the vendor responses for the demo or we push it, I'd rather fake it, wanted you to know now not Wednesday night",
         """
         Heads up, the vendor sandbox went down this morning, and their support says it could take ~48 hours. That pretty much kills our Thursday demo.

         I think we have two options: mock the vendor responses for the demo or push it. I'd lean towards mocking them so we can still do the demo.

         Wanted to flag it now rather than Wednesday night.
         """),
        // E4 — the counted list, as a numbered list with an intro line.
        ("hi so the weekly update, um three things really, the launch prep is on track, QA finishes Wednesday and we're go for Tuesday, second thing the hiring loop, we did four onsites, two strong yes candidates, I'll send the debrief separately, and third, the thing I'm worried about, the vendor contract renewal is stuck with legal and if it slips past Friday it starts blocking the roadmap work, that one needs your help",
         """
         Weekly update, three things:

         1. Launch prep: On track. QA wraps Wednesday, and we're still good for Tuesday.
         2. Hiring: We did 4 onsites and have 2 strong yes candidates. I'll send the debrief separately.
         3. Blocker: The vendor contract renewal is stuck with Legal. If it slips past Friday, it starts blocking roadmap work. This one needs your help.
         """),
    ]

    /// The examples as chat messages, in the order the API wants them.
    private static var exampleMessages: [[String: String]] {
        examples.flatMap { [["role": "user", "content": $0.spoken],
                            ["role": "assistant", "content": $0.written
                                .trimmingCharacters(in: .whitespacesAndNewlines)]] }
    }

    /// The exact system message a rewrite would receive, minus the pinned
    /// facts (which are per-utterance). Exposed for `--dump-config` so the
    /// eval reads the shipping prompt instead of a copy.
    static func promptForContext(_ context: AppContext, signOffName: String) -> String {
        [workPrompt, register(for: context, signOffName: signOffName)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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

    func rewrite(_ raw: String, context: AppContext,
                 signOffName: String = "") async throws -> Outcome {
        let facts = FactGuard.extract(from: raw)
        let pinned = FactGuard.promptBlock(for: facts)
        let system = [Self.workPrompt, Self.register(for: context, signOffName: signOffName), pinned]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let first = try await withTimeout(Self.timeout) {
            try await self.ask(system: system,
                               messages: Self.exampleMessages
                                   + [["role": "user", "content": raw]])
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
            try await self.ask(system: system, messages: Self.exampleMessages + [
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
