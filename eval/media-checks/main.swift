import Foundation

// Deterministic checks for the media family. Neither of the two things
// tested here needs audio to be playing, which is the point — the parts
// that decide *what to say* must be checkable without a live music player,
// because that is the half that can be silently wrong.

var failures: [String] = []

func check(_ label: String, _ condition: @autoclosure () -> Bool) {
    if !condition() { failures.append(label) }
}

// MARK: - Classification decides which route, and so which promises we can make

check("Music is scriptable", MediaTarget.classify(appName: "Music") == .scriptable(app: "Music"))
check("Spotify is scriptable", MediaTarget.classify(appName: "Spotify") == .scriptable(app: "Spotify"))
check("iTunes is scriptable", MediaTarget.classify(appName: "iTunes") == .scriptable(app: "iTunes"))
check("case is ignored", MediaTarget.classify(appName: "spotify") == .scriptable(app: "spotify"))

check("Safari is a browser", MediaTarget.classify(appName: "Safari") == .browser(app: "Safari"))
check("Chrome is a browser", MediaTarget.classify(appName: "Google Chrome") == .browser(app: "Google Chrome"))
check("Chrome Helper is a browser",
      MediaTarget.classify(appName: "Google Chrome Helper") == .browser(app: "Google Chrome Helper"))
check("Arc is a browser", MediaTarget.classify(appName: "Arc") == .browser(app: "Arc"))
check("Brave is a browser", MediaTarget.classify(appName: "Brave Browser") == .browser(app: "Brave Browser"))
check("Firefox is a browser", MediaTarget.classify(appName: "Firefox") == .browser(app: "Firefox"))

check("VLC is other", MediaTarget.classify(appName: "VLC") == .other(app: "VLC"))
check("an unknown app is other", MediaTarget.classify(appName: "Sonos") == .other(app: "Sonos"))

// The property the phrasing rule actually keys off.
check("scriptable state is queryable", MediaTarget.classify(appName: "Music").stateIsQueryable)
check("browser state is not queryable", !MediaTarget.classify(appName: "Safari").stateIsQueryable)
check("other state is not queryable", !MediaTarget.classify(appName: "VLC").stateIsQueryable)

// MARK: - Phrase per mechanism, never per guess (Fable A6)
//
// The rule these enforce: when the app can be asked what it is doing, the
// sentence describes an outcome. When it cannot, the sentence describes
// only what was sent. The detector reports "holds an audio stream open",
// not "is audible" — a browser listed as playing may have been paused all
// along, so a confident "Paused Chrome" would be an invention.

let spotify = MediaTarget.scriptable(app: "Spotify")
let chrome = MediaTarget.browser(app: "Google Chrome")
let vlc = MediaTarget.other(app: "VLC")

check("queryable pause reports the outcome",
      MediaControl.sentence(for: .pause, target: spotify, observedState: .paused) == "Paused Spotify")
check("queryable play reports the outcome",
      MediaControl.sentence(for: .play, target: spotify, observedState: .playing) == "Playing Spotify")

// The honest half of being able to ask: sometimes the answer is that it
// did not work, and saying so beats a cheerful lie.
check("pause that did not take is admitted",
      MediaControl.sentence(for: .pause, target: spotify, observedState: .playing)
        == "Spotify is still playing")
check("play that did not take is admitted",
      MediaControl.sentence(for: .play, target: spotify, observedState: .paused)
        == "Spotify didn't start")

check("browser pause claims only the send",
      MediaControl.sentence(for: .pause, target: chrome, observedState: nil)
        == "Sent play/pause to Google Chrome")
check("browser play claims only the send",
      MediaControl.sentence(for: .play, target: chrome, observedState: nil)
        == "Sent play/pause to Google Chrome")
check("browser skip claims only the send",
      MediaControl.sentence(for: .next, target: chrome, observedState: nil)
        == "Sent skip to Google Chrome")
check("unknown apps get the same treatment as browsers",
      MediaControl.sentence(for: .pause, target: vlc, observedState: nil) == "Sent play/pause to VLC")

// The trap: a state passed alongside a target that cannot actually be
// queried must still not produce an outcome claim. Only the target's
// route decides, never the presence of a value.
check("a browser never claims an outcome even if handed a state",
      MediaControl.sentence(for: .pause, target: chrome, observedState: .paused)
        == "Sent play/pause to Google Chrome")

// One key toggles both directions, so naming a direction we did not
// control would be inventing detail.
check("browser play and pause are worded identically",
      MediaControl.sentence(for: .play, target: chrome, observedState: nil)
        == MediaControl.sentence(for: .pause, target: chrome, observedState: nil))

// MARK: - Tab situation decides whether closing is safe or needs asking

// Cmd+W closes the front WINDOW. On a window down to one tab that closes
// the lot — which is how "close this tab" shut a whole Chrome window full
// of open links on 2026-08-12. These pin the distinction the fix rests on.
check("many tabs closes one silently",
      MediaControl.TabSituation.oneOfMany(remaining: 4) != .lastTab)
check("last tab is its own case",
      MediaControl.TabSituation.lastTab == .lastTab)
check("unscriptable browser is not mistaken for a safe close",
      MediaControl.TabSituation.unknown != .oneOfMany(remaining: 1))
check("remaining count is carried, so the message can be specific",
      MediaControl.TabSituation.oneOfMany(remaining: 4) == .oneOfMany(remaining: 4))

// MARK: - Report

if failures.isEmpty {
    print("all passed (\(28) checks)")
} else {
    print("FAILED:")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
