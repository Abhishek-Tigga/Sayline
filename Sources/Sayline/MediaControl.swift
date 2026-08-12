import Foundation
import AppKit

/// Commands that act on whatever is already playing.
///
/// No destination, no arguments — which is what separates them from every
/// other action in this app. "Stop the music" was answered for weeks by
/// opening YouTube again, because the only vocabulary available was
/// "hear words, build a URL, open it".
enum MediaCommand: String, CaseIterable {
    case play = "Play"
    case pause = "Pause"
    case next = "Next"
    case previous = "Previous"
}

/// Drives whatever is playing, by the best route available for that app.
///
/// Two routes, deliberately not unified:
///
/// - **AppleScript**, for Music and Spotify. Their player state can be
///   read back, so the sentence shown to the user can describe what
///   actually happened.
/// - **A system media key**, for browsers and anything unrecognised. It is
///   broadcast and fire-and-forget: nothing comes back, so nothing about
///   the outcome may be claimed.
///
/// Routing per target rather than broadcasting one key at everything is a
/// direct result of measurement. On 2026-08-12 a posted play key resumed a
/// paused Chrome tab, and three further presses failed to pause it again;
/// repeated attempts afterwards could not get a browser tab into a
/// reproducible playing state at all. A key that behaves differently run to
/// run cannot be the whole feature — but it is a fine last resort, provided
/// we never pretend to know what it did.
enum MediaControl {

    /// Acts, then returns the sentence to show. Never claims more than the
    /// route can support.
    static func perform(_ command: MediaCommand, on target: MediaTarget) -> String {
        switch target {
        case .scriptable(let app):
            let worked = runScript(command, app: app)
            guard worked else {
                // Almost always a declined or not-yet-granted Automation
                // prompt. Say which app, because the fix is per-app.
                return "Couldn't control \(app) — check Automation permission in Privacy & Security."
            }
            return sentence(for: command, target: target, observedState: playerState(of: app))
        case .browser, .other:
            postMediaKey(command)
            return sentence(for: command, target: target, observedState: nil)
        }
    }

    // MARK: - Wording

    /// Pure, and the whole point of A6: phrase per mechanism, never per
    /// guess.
    ///
    /// When the app can be asked what it is doing, say what happened —
    /// "Paused Spotify". When it cannot, say only what was sent — "Sent
    /// pause to Chrome". The second is wordier on purpose. The detector
    /// reports "holds an audio stream open", not "is audible", so a browser
    /// listed as playing may have been paused all along; a confident
    /// "Paused Chrome" would then be exactly the silent wrongness this
    /// project keeps paying to remove.
    static func sentence(for command: MediaCommand,
                         target: MediaTarget,
                         observedState: PlayerState?) -> String {
        let app = target.appName
        guard target.stateIsQueryable, let observedState else {
            switch command {
            case .play, .pause:
                // One key toggles both, so naming a direction we did not
                // control would be an invention.
                return "Sent play/pause to \(app)"
            case .next: return "Sent skip to \(app)"
            case .previous: return "Sent previous to \(app)"
            }
        }
        switch (command, observedState) {
        case (.pause, .paused): return "Paused \(app)"
        case (.pause, .playing): return "\(app) is still playing"
        case (.play, .playing): return "Playing \(app)"
        case (.play, .paused): return "\(app) didn't start"
        case (.next, _): return "Skipped ahead in \(app)"
        case (.previous, _): return "Went back in \(app)"
        case (_, .stopped): return "\(app) is stopped"
        }
    }

    enum PlayerState { case playing, paused, stopped }

    // MARK: - AppleScript route

    private static func runScript(_ command: MediaCommand, app: String) -> Bool {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        return execute("tell application \"\(app)\" to \(verb)") != nil
    }

    private static func playerState(of app: String) -> PlayerState? {
        guard let value = execute("tell application \"\(app)\" to return player state as string") else {
            return nil
        }
        switch value.lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        default: return .stopped
        }
    }

    @discardableResult
    private static func execute(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            SaylineLog.log("media applescript failed: \(error?[NSAppleScript.errorMessage] ?? "?")")
            return nil
        }
        return result.stringValue ?? ""
    }

    // MARK: - Media key route

    /// Posts a system-defined media key as a proper down/up pair.
    ///
    /// The pair matters: `data1` carries the key code in its high 16 bits
    /// and the state (0xA down, 0xB up) in the next byte. Posting only the
    /// down half can be delivered as a bare "play", which is idempotent —
    /// it resumes a paused player and does nothing to a playing one.
    ///
    /// Rides the Accessibility grant the hotkey already needs, so it asks
    /// for no new permission.
    private static func postMediaKey(_ command: MediaCommand) {
        let key: Int32
        switch command {
        case .play, .pause: key = 16   // NX_KEYTYPE_PLAY — one toggle for both
        case .next: key = 17           // NX_KEYTYPE_NEXT
        case .previous: key = 18       // NX_KEYTYPE_PREVIOUS
        }
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(isDown ? 0xA00 : 0xB00))
            let data1 = Int((key << 16) | ((isDown ? 0xA : 0xB) << 8))
            guard let event = NSEvent.otherEvent(with: .systemDefined,
                                                 location: .zero,
                                                 modifierFlags: flags,
                                                 timestamp: 0,
                                                 windowNumber: 0,
                                                 context: nil,
                                                 subtype: 8,
                                                 data1: data1,
                                                 data2: -1) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
