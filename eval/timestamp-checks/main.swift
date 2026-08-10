// Checks LocalTimestamp — the parser between the model's answer and a real
// reminder.
//
// Exists because ISO8601DateFormatter was used here first and looked
// correct. It requires seconds, so "2026-08-12T12:00" parsed as nil, and
// every reminder said in one sentence lost its time and asked the user for
// one they had already given. The first case below is that bug.
//
// Run: swiftc -o /tmp/tschk Sources/Sayline/LocalTimestamp.swift eval/timestamp-checks/main.swift && /tmp/tschk
import Foundation

var bad = 0
let cal = Calendar.current

func check(_ text: String, _ expect: (y: Int, mo: Int, d: Int, h: Int, mi: Int)?) {
    let got = LocalTimestamp.parse(text)
    guard let expect else {
        if got == nil { print("  ok    \"\(text)\" -> nil") }
        else { print("  FAIL  \"\(text)\" -> \(got!), expected nil"); bad += 1 }
        return
    }
    guard let got else { print("  FAIL  \"\(text)\" -> nil, expected a date"); bad += 1; return }
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: got)
    if (c.year, c.month, c.day, c.hour, c.minute) == (expect.y, expect.mo, expect.d, expect.h, expect.mi) {
        print("  ok    \"\(text)\" -> \(got)")
    } else {
        print("  FAIL  \"\(text)\" -> \(got), expected \(expect)"); bad += 1
    }
}

print("what the model actually writes")
check("2026-08-12T12:00", (2026, 8, 12, 12, 0))     // the bug: parsed as nil
check("2026-08-11T16:00", (2026, 8, 11, 16, 0))
check("2026-08-12T12:00:00", (2026, 8, 12, 12, 0))
check("2026-08-12 12:00", (2026, 8, 12, 12, 0))
check("2026-08-12", (2026, 8, 12, 0, 0))

// A model that volunteers an offset is still answering the question. The
// ISO fallback takes it and converts to local, rather than losing the time
// on a formality. Asserted in local components, so this holds anywhere.
print("\nan offset is still an answer")
if let utc = LocalTimestamp.parse("2026-08-12T12:00:00Z") {
    let expected = ISO8601DateFormatter().date(from: "2026-08-12T12:00:00Z")!
    if abs(utc.timeIntervalSince(expected)) < 1 {
        print("  ok    \"2026-08-12T12:00:00Z\" -> \(utc)")
    } else {
        print("  FAIL  Z offset landed at \(utc)"); bad += 1
    }
} else {
    print("  FAIL  Z offset parsed as nil"); bad += 1
}

print("\nnot times")
for t in ["", "   ", "tomorrow", "banana", "12:00"] { check(t, nil) }

print("\nround trip")
let now = Date()
let text = LocalTimestamp.string(from: now)
if let back = LocalTimestamp.parse(text), abs(back.timeIntervalSince(now)) < 1 {
    print("  ok    \(text) survives a round trip")
} else {
    print("  FAIL  \(text) did not round trip"); bad += 1
}

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
