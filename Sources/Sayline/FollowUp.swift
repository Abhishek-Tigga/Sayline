import Foundation

/// A question Sayline asks and then waits for an answer to.
///
/// Agent mode is otherwise one-shot: speak, act, done. Two decisions in
/// DESIGN-meetings-reminders.md need a second turn — "remind me to call the
/// bank" with no time, and offering to open System Settings after a denied
/// permission — and neither is possible without this.
///
/// Two kinds, because the two questions want different answers. A yes/no
/// gets buttons: reaching for a hotkey to say "yes" is heavier than
/// clicking. A value gets voice, reusing hold-and-speak, because a time is
/// a real phrase rather than a choice from a list.
///
/// The rejected third option was reopening the microphone automatically
/// after a question. It reads better on paper and would have removed the
/// keyboard hint entirely, but it means Sayline starts listening without
/// being asked. A dictation app should never do that quietly.

/// A button that stands in for something the user could have said. Click
/// and speech deliver the same `.spoken` answer, so callers parse one
/// thing rather than branching on how the answer arrived.
struct QuickChoice: Equatable {
    let label: String
    let spoken: String
}

struct FollowUpRequest: Equatable {
    enum Kind: Equatable {
        /// Two buttons. `primary` is the affirmative and is styled as the
        /// default; `secondary` dismisses.
        case confirm(primary: String, secondary: String)
        /// Answered by holding the hotkey and speaking. `hint` names the
        /// key, because nothing else on screen says the mic is closed —
        /// without it people talk into a microphone that isn't listening.
        case value(hint: String)
    }

    let question: String
    /// Shown emphasised under the question. Carries the thing being acted
    /// on — the reminder about to be deleted, the meeting about to be
    /// joined — so a wrong match is visible before the button is pressed
    /// rather than after.
    let detail: String?
    let kind: Kind
    /// Shown as buttons alongside whatever the kind provides. Every
    /// question is answerable both ways — by voice when your hands are
    /// elsewhere, by click when they are on the trackpad.
    let quickChoices: [QuickChoice]
    /// Styles the primary button as destructive. EventKit deletion is
    /// permanent and "cancel that" only covers the last thing *created*,
    /// so a delete needs to look different from an open.
    let isDestructive: Bool
    /// What silence means.
    ///
    /// Everywhere else in the app it means no, because everywhere else the
    /// irreversible direction is yes — deleting a reminder, emptying the
    /// Trash. Joining a meeting inverts that: the cost of joining one you
    /// did not want is leaving it, and the cost of *not* joining is missing
    /// the meeting you asked for. So there, and only there, silence means
    /// go.
    ///
    /// Stated as its own field rather than hidden in a caller, because
    /// "never guess yes" is a rule this codebase relies on and an exception
    /// to it should be visible at the call site.
    let timeoutMeans: TimeoutOutcome
    /// Overrides the default window. A confirmation that will act on its
    /// own wants less time than one that will quietly go away.
    let timeout: TimeInterval

    init(question: String,
         detail: String? = nil,
         kind: Kind,
         quickChoices: [QuickChoice] = [],
         isDestructive: Bool = false,
         timeoutMeans: TimeoutOutcome = .declined,
         timeout: TimeInterval = followUpTimeout) {
        self.question = question
        self.detail = detail
        self.kind = kind
        self.quickChoices = quickChoices
        self.isDestructive = isDestructive
        self.timeoutMeans = timeoutMeans
        self.timeout = timeout
        // A question that destroys something and proceeds on silence is
        // never what anyone meant. Absent by convention until now; this
        // makes it unrepresentable, which is the difference between a rule
        // and a habit.
        precondition(!(isDestructive && timeoutMeans == .confirmed),
                     "a destructive question must never confirm on timeout")
    }
}

/// Reads yes or no out of a spoken sentence.
///
/// Negatives are tested before affirmatives on purpose. "Yes, but not now"
/// contains both, and the safe direction is the one that does not delete a
/// reminder or open a settings pane nobody asked for. Anything genuinely
/// unreadable comes back `.unclear`, which costs one more question rather
/// than a guess.
enum SpokenConsent {
    case affirmative, negative, unclear

    private static let no = [
        "never mind", "nevermind", "forget it", "not now", "no thanks",
        "do not", "don't", "keep it", "leave it", "cancel", "stop", "skip",
        "dismiss", "close", "later", "nope", "nah", "no",
    ]
    private static let yes = [
        "go ahead", "do it", "yes please", "delete it", "open it",
        "open settings", "sounds good", "that's right", "thats right",
        "confirm", "correct", "sure", "okay", "yeah", "yep", "yup", "ok",
        "alright", "please", "yes",
    ]

    static func read(_ text: String) -> SpokenConsent {
        let normalized = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return .unclear }
        if no.contains(where: { contains(normalized, $0) }) { return .negative }
        if yes.contains(where: { contains(normalized, $0) }) { return .affirmative }
        return .unclear
    }

    /// Whole-phrase match. Substring matching would read "no" out of "now"
    /// and decline something the user agreed to.
    private static func contains(_ haystack: String, _ phrase: String) -> Bool {
        haystack == phrase
            || haystack.hasPrefix(phrase + " ")
            || haystack.hasSuffix(" " + phrase)
            || haystack.contains(" " + phrase + " ")
    }
}

enum TimeoutOutcome: Equatable {
    /// Silence is a no. The default, and right for anything irreversible.
    case declined
    /// Silence is a yes, and the countdown is a grace period rather than a
    /// deadline. Only for actions where doing nothing is the worse outcome.
    case confirmed
}

enum FollowUpAnswer: Equatable {
    case confirmed
    case declined
    case spoken(String)
    /// Nobody answered within the window. Callers must treat this as a
    /// real outcome with a safe fallback, never as a failure to report:
    /// an unanswered "what time?" still creates the reminder undated,
    /// because the reminder is never lost.
    case timedOut
}

/// How long a question stays on screen before taking its fallback.
///
/// Long enough to read and think, short enough that a forgotten question
/// isn't left sitting over someone's work. The countdown is drawn as a
/// draining line rather than left invisible — a question that vanishes
/// with no warning reads as a bug, one with a deadline reads as a deadline.
let followUpTimeout: TimeInterval = 20
