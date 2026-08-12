import Foundation
import CoreAudio
import AppKit

/// Who is making sound right now, and how we can talk to them.
///
/// "Stop the music" names no destination, so before anything can be done
/// the target has to be found. macOS 14.2 added a public per-process audio
/// API that answers this exactly; probed on 2026-08-12, it caught a process
/// starting and stopping playback and named it.
///
/// The important distinction it lets us draw is not *what* is playing but
/// *how it can be controlled*. Music and Spotify answer AppleScript and
/// will tell you their player state, so an outcome can be reported
/// honestly. A browser tab cannot be asked anything — the only lever is a
/// system media key, which is fire-and-forget. Reporting those two the same
/// way would mean claiming outcomes we never observed.
enum MediaTarget: Equatable {
    /// Answers AppleScript, and its state can be queried.
    case scriptable(app: String)
    /// A browser. Media keys only, no readback.
    case browser(app: String)
    /// Making sound, but we know nothing about how to drive it.
    case other(app: String)

    var appName: String {
        switch self {
        case .scriptable(let app), .browser(let app), .other(let app): return app
        }
    }

    /// True when we can ask this app what actually happened afterwards.
    var stateIsQueryable: Bool {
        if case .scriptable = self { return true }
        return false
    }

    /// Pure, so it can be tested without any audio playing.
    ///
    /// Matched on the app's display name rather than bundle identifier
    /// because that is what the audio process list gives us, and because
    /// Chrome ships under several names (Chrome, Chrome Beta, Chromium)
    /// that all behave identically here.
    static func classify(appName: String) -> MediaTarget {
        let name = appName.lowercased()
        if name == "music" || name == "itunes" || name == "spotify" {
            return .scriptable(app: appName)
        }
        let browsers = ["safari", "chrome", "chromium", "firefox", "arc",
                        "brave", "edge", "opera", "vivaldi", "orion", "zen"]
        if browsers.contains(where: { name.contains($0) }) {
            return .browser(app: appName)
        }
        return .other(app: appName)
    }

    // MARK: - Detection

    /// Every app currently sending audio to the default output, never
    /// including Sayline itself.
    ///
    /// We are always in this list — the microphone engine holds an output
    /// stream open for the whole session — so excluding our own PID is not
    /// tidiness, it is the difference between "nothing is playing" and
    /// "something is". The first version of this used the device-level
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere`, which reported
    /// `true` in silence for exactly that reason and was useless.
    static func audible() -> [MediaTarget] {
        audibleAppNames().map(classify(appName:))
    }

    /// Names only, so callers that just want to say what is playing do not
    /// have to care how it is controlled.
    static func audibleAppNames() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }

        let me = getpid()
        var names: [String] = []
        for object in processObjects() {
            guard let running = uint32(object, kAudioProcessPropertyIsRunningOutput),
                  running != 0,
                  let raw = uint32(object, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: raw)
            guard pid != me else { continue }
            // A helper process (Chrome's audio lives in one) has no
            // NSRunningApplication of its own; fall back to its parent's
            // name via the process list rather than printing a bare PID at
            // someone.
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? owningAppName(forPID: pid)
            if let name, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Reports *only* what we are sure about.
    ///
    /// This detector means "holds an output stream open", not "is audible".
    /// Chrome keeps a stream open with a paused tab, so a non-empty result
    /// is a strong candidate rather than proof — which is exactly why the
    /// browser path never claims an outcome. An empty result, though, is
    /// trustworthy: nothing at all is holding output.
    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// Maps a helper PID back to the app a person would recognise.
    ///
    /// Chrome plays audio from "Google Chrome Helper", which is not an
    /// `NSRunningApplication` and would otherwise surface to the user as
    /// "pid 5678" — measured during the probes on 2026-08-12.
    private static func owningAppName(forPID pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }

        // ".../Google Chrome.app/Contents/Frameworks/... Helper" — the
        // first .app component is the one with a name people know.
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return path.split(separator: "/").last.map(String.init)
    }
}
