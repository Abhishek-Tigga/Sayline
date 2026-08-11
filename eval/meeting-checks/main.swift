// Checks the two pure decisions in the meetings feature: which meeting is
// "next", and which URL is a join link.
//
// Ships with the feature rather than after it, deliberately. The reminders
// build left ReminderStore's scoring untestable because it needs a live
// EventKit database, and that is still on the parked list. The logic that
// decides which meeting someone is dropped into does not get to join it.
//
// The extraction cases matter most. Notes are written by whoever sent the
// invite, so "returns nil for a non-provider URL" is the trust boundary
// expressed as a test — if that case ever goes green-to-red, a voice
// command can be made to open a stranger's link.
//
// Run: swiftc -o /tmp/mtchk Sources/Sayline/Meeting.swift \
//        Sources/Sayline/MeetingLink.swift eval/meeting-checks/main.swift && /tmp/mtchk
import Foundation

var bad = 0

func check(_ label: String, _ condition: Bool) {
    if condition { print("  ok    \(label)") }
    else { print("  FAIL  \(label)"); bad += 1 }
}

// Fixed clock — a test that reads the wall clock is a test that fails at
// midnight, and this decides which meeting someone joins.
let now = Date(timeIntervalSince1970: 1_770_000_000)   // arbitrary, stable
func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
let zoom = URL(string: "https://acme.zoom.us/j/9876543210")!

func meeting(_ title: String, from: Double, to: Double,
             link: URL? = zoom, accepted: Bool = true) -> Meeting {
    Meeting(title: title, start: at(from), end: at(to), joinURL: link, isAccepted: accepted)
}

// ---- selection ------------------------------------------------------
print("which meeting is next")

check("starting in 10 minutes is in the window",
      MeetingSelection.nextJoinable(from: [meeting("Standup", from: 10, to: 40)], now: now)?.title == "Standup")

check("running right now wins — being late is the point",
      MeetingSelection.nextJoinable(from: [meeting("Design review", from: -15, to: 15)], now: now)?.title == "Design review")

check("starting in 45 minutes is outside the 30-minute window",
      MeetingSelection.nextJoinable(from: [meeting("Later", from: 45, to: 75)], now: now) == nil)

check("already finished does not count",
      MeetingSelection.nextJoinable(from: [meeting("Over", from: -90, to: -30)], now: now) == nil)

check("soonest start wins",
      MeetingSelection.nextJoinable(from: [
        meeting("Later", from: 25, to: 55), meeting("Sooner", from: 5, to: 35),
      ], now: now)?.title == "Sooner")

check("same start time — the accepted one wins",
      MeetingSelection.nextJoinable(from: [
        meeting("Maybe", from: 10, to: 40, accepted: false),
        meeting("Accepted", from: 10, to: 40, accepted: true),
      ], now: now)?.title == "Accepted")

check("a linkless event never wins join, even when sooner",
      MeetingSelection.nextJoinable(from: [
        meeting("Focus block", from: 2, to: 60, link: nil),
        meeting("Standup", from: 20, to: 50),
      ], now: now)?.title == "Standup")

check("an all-day holiday with no link never wins join",
      MeetingSelection.nextJoinable(from: [
        meeting("Independence Day", from: -600, to: 840, link: nil),
      ], now: now) == nil)

check("but 'what's next' still reports the linkless one — saying 'no meetings' would be false",
      MeetingSelection.next(from: [meeting("Focus block", from: 5, to: 65, link: nil)], now: now)?.title == "Focus block")

check("empty calendar is nil, not a crash",
      MeetingSelection.nextJoinable(from: [], now: now) == nil)

check("the same meeting on two calendars picks one and both carry the link",
      MeetingSelection.nextJoinable(from: [
        meeting("Standup", from: 10, to: 40), meeting("Standup", from: 10, to: 40),
      ], now: now)?.joinURL == zoom)

check("an untitled event is announceable rather than blank",
      meeting("   ", from: 10, to: 40).spokenName == "Untitled meeting")

// ---- extraction -----------------------------------------------------
print("\nwhich URL is a join link")

func extract(url: String? = nil, location: String? = nil, notes: String? = nil) -> URL? {
    MeetingLink.extract(url: url.flatMap(URL.init(string:)), location: location, notes: notes)
}

check("Zoom in the url field",
      extract(url: "https://acme.zoom.us/j/9876543210") != nil)
check("Zoom in the location field",
      extract(location: "https://zoom.us/j/123456") != nil)
check("Google Meet in the notes",
      extract(notes: "Dial in: https://meet.google.com/abc-defg-hij") != nil)
check("Teams' meetup-join monstrosity",
      extract(notes: "Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0") != nil)
check("Webex on a company subdomain",
      extract(url: "https://acme.webex.com/meet/jsmith") != nil)

print("\n  the trust boundary — notes are written by whoever sent the invite")
check("a survey link BEFORE a Meet link still yields the Meet link",
      extract(notes: """
        Thanks for joining! Rate us: https://surveymonkey.com/r/XYZ123
        Meeting: https://meet.google.com/abc-defg-hij
        """)?.host == "meet.google.com")
check("notes with ONLY a non-provider URL return nil, never that URL",
      extract(notes: "Agenda and pre-read: https://evil.example.com/steal") == nil)
check("a provider name inside a hostile URL does not pass",
      extract(notes: "https://evil.example.com/?next=zoom.us/j/1") == nil)
check("a lookalike domain does not pass — the boundary must be a dot",
      extract(notes: "https://notzoom.us/j/123") == nil)
check("zoom.us without a meeting path is not a join link",
      extract(notes: "Read more at https://zoom.us/pricing") == nil)
// A well-named host is not enough. The url field is attacker-writable and
// goes straight to NSWorkspace.open, so a file:// URL wearing a provider
// hostname would have been opened as a file.
check("a file:// URL with a provider host is refused",
      extract(url: "file://zoom.us/j/9876543210") == nil)
check("a non-web scheme in notes is refused",
      extract(notes: "Join: ftp://meet.google.com/abc-defg-hij") == nil)

print("\n  nothing to find")
check("plain-text notes", extract(notes: "Bring the deck. Room 4.") == nil)
check("all fields empty", extract() == nil)
check("empty strings", extract(url: nil, location: "", notes: "") == nil)

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
