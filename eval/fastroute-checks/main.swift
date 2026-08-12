// Checks FastRoute — the local matcher that answers easy commands without
// a round trip to the model.
//
// The negative cases matter more than the positive ones. A false positive
// here does not merely give a wrong answer, it silently drops the rest of
// the sentence: "open Safari and check my battery" answered as "open
// Safari" loses half of what was asked, with nothing to show it happened.
// This is the same failure VoiceCommand hit when "scratch that idea"
// scored 0.94 against "scratch that".
//
// Run: swiftc -o /tmp/frchk Sources/Sayline/AgentAction.swift \
//        Sources/Sayline/WebsiteCatalog.swift Sources/Sayline/InstalledAppCatalog.swift \
//        Sources/Sayline/FastRoute.swift eval/fastroute-checks/main.swift && /tmp/frchk
import Foundation

var bad = 0

func matches(_ text: String, _ expected: String) {
    let got = FastRoute.action(for: text)
    let describe = got.map { "\($0)" } ?? "nil"
    if describe.contains(expected) { print("  ok    \"\(text)\" -> \(describe)") }
    else { print("  FAIL  \"\(text)\" -> \(describe), wanted \(expected)"); bad += 1 }
}

func falls(_ text: String, _ why: String) {
    let got = FastRoute.action(for: text)
    if got == nil { print("  ok    \"\(text)\" -> router  (\(why))") }
    else { print("  FAIL  \"\(text)\" -> \(got!), should reach the router  (\(why))"); bad += 1 }
}

print("no-argument commands")
matches("Lock the screen.", "lockScreen")
matches("lock my mac", "lockScreen")
matches("Please take a screenshot", "takeScreenshot")
matches("empty the trash", "emptyTrash")
matches("mute", "setVolume")
matches("turn on dark mode", "setDarkMode(enabled: true)")
matches("turn off wifi", "setWiFi(enabled: false)")

print("\nquestions about this Mac")
matches("what's my battery", "battery")
matches("How much storage do I have?", "storage")
matches("what's playing", "nowPlaying")

print("\napps that are installed here")
matches("Open Safari", "openApp")
matches("open safari.", "openApp")
matches("close Finder", "closeApp")

print("\nmeetings — the commonest command, answered with no round trip")
matches("Join my next meeting", "joinMeeting")
matches("join my meeting", "joinMeeting")
matches("Hop on my call.", "joinMeeting")
matches("what's my next meeting", "whatsNextMeeting")
matches("When is my next call?", "whatsNextMeeting")

print("\nmeetings — must reach the router")
falls("join the design review", "named-meeting join is not in v1")
falls("what's my next reminder", "a reminder, not a meeting")
falls("cancel my next meeting", "calendar writes are out of scope")
falls("what meetings do I have today", "list-shaped, parked")

print("\nmedia control — fixed vocabulary, so it must never pay the round trip")
matches("stop the music", "controlMedia")
matches("Stop the music.", "controlMedia")
matches("pause", "controlMedia")
matches("pause it", "controlMedia")
matches("stop", "controlMedia")
matches("next song", "controlMedia")
matches("skip this song", "controlMedia")
matches("previous track", "controlMedia")
matches("resume", "controlMedia")
matches("unpause", "controlMedia")
matches("close this tab", "closeCurrentTab")
matches("close the tab", "closeCurrentTab")

print("\nmedia — wants music, named none: ask rather than guess")
// These name no track, so they are the ask-flow — now fast-routed, since
// the answer is a question we already know to ask.
matches("play music", "askWhatToPlay")
matches("Play some music.", "askWhatToPlay")
matches("play a song", "askWhatToPlay")
matches("put on some music", "askWhatToPlay")
matches("play something", "askWhatToPlay")
// Named music is a search, not a transport command.
falls("play lo-fi on YouTube", "names what to play")
falls("play Bohemian Rhapsody", "names a track")
// Volume already has its own routed, tested action; there is no media
// mute case and this must not start matching one.
matches("mute", "setVolume")
matches("louder", "setVolume")
falls("stop the video in Chrome", "names an app — not whole-utterance")
falls("pause my meeting", "not a media command")

print("\nMUST reach the router — a wrong answer here eats the sentence")
falls("open Safari and check my battery", "two commands in one utterance")
falls("lock the screen then open Safari", "two commands")
falls("open YouTube", "a website, not an app")
falls("open Amazon", "a website")
falls("open Florble", "no such app installed")
falls("search for headphones on Amazon", "a search")
falls("remind me to call the bank at 4pm", "a reminder")
falls("what's the population of India", "a real question")
falls("open the iPhone page on Apple", "a website page")
falls("turn the volume up in Spotify", "not the system volume")
falls("battery of my airpods", "not the Mac's battery")

print("\n\(bad == 0 ? "all passed" : "\(bad) FAILED")")
exit(bad == 0 ? 0 : 1)
