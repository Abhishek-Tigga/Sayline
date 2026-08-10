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
    /// Styles the primary button as destructive. EventKit deletion is
    /// permanent and "cancel that" only covers the last thing *created*,
    /// so a delete needs to look different from an open.
    let isDestructive: Bool

    init(question: String, detail: String? = nil, kind: Kind, isDestructive: Bool = false) {
        self.question = question
        self.detail = detail
        self.kind = kind
        self.isDestructive = isDestructive
    }
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
