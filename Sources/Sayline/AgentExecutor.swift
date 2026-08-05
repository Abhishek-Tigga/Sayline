import AppKit
import CoreGraphics
import Foundation

enum AgentExecutor {
    /// Returns whether the action actually did something concrete — lets
    /// the caller surface visible feedback on failure (no match, app not
    /// found, pane failed to open) instead of the previous behavior of
    /// failing completely silently, which made "nothing happened because
    /// it failed" indistinguishable from "nothing happened because it
    /// succeeded quietly" during live testing.
    @discardableResult
    static func execute(_ action: AgentAction) -> Bool {
        switch action {
        case .openApp(let name):
            return openApp(named: name)
        case .closeApp(let name):
            return closeApp(named: name)
        case .findFile(let query, let folder, let subpath):
            return findFile(query: query, in: folder, subpath: subpath)
        case .openFolder(let folder, let subpath):
            return openFolder(folder, subpath: subpath)
        case .openSystemSetting(let pane):
            return openSystemSetting(pane)
        case .lockScreen:
            return lockScreen()
        case .setVolume(let change):
            return setVolume(change)
        case .setWiFi(let enabled):
            return setWiFi(enabled: enabled)
        case .setDarkMode(let enabled):
            return setDarkMode(enabled: enabled)
        case .emptyTrash:
            return emptyTrash()
        case .takeScreenshot:
            return takeScreenshot()
        }
    }

    /// Sends a normal terminate request (equivalent to Cmd+Q) rather than
    /// force-killing — respects the app's own unsaved-changes prompt
    /// instead of silently discarding work.
    @discardableResult
    private static func closeApp(named name: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            NSLog("Sayline: agent could not find a running app named \(name) to close")
            return false
        }
        let didTerminate = app.terminate()
        NSLog("Sayline: agent closed app -> \(name) (requested: \(didTerminate))")
        return didTerminate
    }

    @discardableResult
    private static func openSystemSetting(_ pane: AgentAction.SettingsPane) -> Bool {
        guard let url = URL(string: settingsURLString(for: pane)) else { return false }
        let opened = NSWorkspace.shared.open(url)
        NSLog("Sayline: agent opened system setting -> \(pane.rawValue) (success: \(opened))")
        return opened
    }

    // Modern extension bundle identifiers, pulled directly from
    // /System/Library/ExtensionKit/Extensions/*.appex/Contents/Info.plist
    // on a live machine rather than guessed — several of the old
    // com.apple.preference.* legacy IDs turned out to be wrong or to
    // have been reassigned to a different pane (e.g. "general" now
    // belongs to Appearance, not General; Network and Wi-Fi share one
    // legacy ID and macOS picks Wi-Fi). Still version-fragile in
    // principle, but these are verified against an actual install.
    private static func settingsURLString(for pane: AgentAction.SettingsPane) -> String {
        switch pane {
        case .privacySecurity: return "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        case .notifications: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .general: return "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings"
        case .displays: return "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        case .sound: return "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case .network: return "x-apple.systempreferences:com.apple.Network-Settings.extension"
        case .bluetooth: return "x-apple.systempreferences:com.apple.BluetoothSettings"
        case .wifi: return "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case .users: return "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
        }
    }

    /// Simulates Cmd+Ctrl+Q, the standard system Lock Screen shortcut —
    /// same CGEvent approach as TextInjector's undo, just with an extra
    /// modifier. Works off the same Accessibility trust already granted
    /// for the hotkey/text-insertion, no new permission needed.
    @discardableResult
    private static func lockScreen() -> Bool {
        simulateKeyCombo(keyCode: 12, flags: [.maskCommand, .maskControl]) // kVK_ANSI_Q
        NSLog("Sayline: agent locked screen")
        return true
    }

    private static func simulateKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// "set volume" is a built-in AppleScript Standard Additions command
    /// (not "tell application X"), so unlike dark mode / empty trash
    /// below it doesn't need the separate Automation permission grant.
    @discardableResult
    private static func setVolume(_ change: AgentAction.VolumeChange) -> Bool {
        let script: String
        switch change {
        case .mute: script = "set volume output muted true"
        case .unmute: script = "set volume output muted false"
        case .up: script = "set volume output volume ((output volume of (get volume settings)) + 10)"
        case .down: script = "set volume output volume ((output volume of (get volume settings)) - 10)"
        }
        let succeeded = runAppleScript(script)
        NSLog("Sayline: agent set volume -> \(change.rawValue) (success: \(succeeded))")
        return succeeded
    }

    @discardableResult
    private static func setWiFi(enabled: Bool) -> Bool {
        guard let device = wifiDeviceName() else {
            NSLog("Sayline: agent could not determine the Wi-Fi device name")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-setairportpower", device, enabled ? "on" : "off"]
        do {
            try process.run()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            NSLog("Sayline: agent set Wi-Fi \(enabled ? "on" : "off") (success: \(succeeded))")
            return succeeded
        } catch {
            NSLog("Sayline: agent failed to set Wi-Fi -> \(error.localizedDescription)")
            return false
        }
    }

    /// Resolves the actual Wi-Fi hardware port name (usually but not
    /// guaranteed to be "en0") rather than hardcoding it — Mac models
    /// vary, and networksetup needs the exact device name.
    private static func wifiDeviceName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let lines = output.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("Wi-Fi") {
                guard index + 1 < lines.count,
                      let range = lines[index + 1].range(of: "Device: ") else { continue }
                return String(lines[index + 1][range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Targets "System Events", so unlike lock screen / volume this
    /// needs a one-time Automation permission grant the first time it
    /// runs — a separate TCC category from Accessibility, expect a new
    /// system prompt on first use.
    @discardableResult
    private static func setDarkMode(enabled: Bool) -> Bool {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
        let succeeded = runAppleScript(script)
        NSLog("Sayline: agent set dark mode -> \(enabled) (success: \(succeeded))")
        return succeeded
    }

    /// Targets "Finder" — same Automation permission category as dark
    /// mode above, granted separately per target app. Permanently
    /// deletes whatever's in the Trash; that's the Trash's whole job,
    /// but worth noting since it's the one irreversible action here.
    @discardableResult
    private static func emptyTrash() -> Bool {
        let succeeded = runAppleScript("tell application \"Finder\" to empty trash")
        NSLog("Sayline: agent emptied trash (success: \(succeeded))")
        return succeeded
    }

    /// Needs the separate Screen Recording permission (not Accessibility)
    /// — first call will trigger that system prompt.
    @discardableResult
    private static func takeScreenshot() -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Sayline Screenshot \(formatter.string(from: Date())).png"
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [destination.path]
        do {
            try process.run()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            NSLog("Sayline: agent took screenshot -> \(destination.path) (success: \(succeeded))")
            return succeeded
        } catch {
            NSLog("Sayline: agent failed to take screenshot -> \(error.localizedDescription)")
            return false
        }
    }

    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NSLog("Sayline: agent AppleScript failed -> \(error)")
            return false
        }
        return true
    }

    @discardableResult
    private static func openFolder(_ folder: AgentAction.SearchFolder, subpath: String?) -> Bool {
        guard let folderURL = resolvedURL(for: folder, subpath: subpath) else {
            NSLog("Sayline: agent could not resolve folder \(folder.rawValue)/\(subpath ?? "")")
            return false
        }
        let opened = NSWorkspace.shared.open(folderURL)
        NSLog("Sayline: agent opened folder -> \(folderURL.path) (success: \(opened))")
        return opened
    }

    /// Waits for `open` to exit and checks its status rather than firing
    /// and forgetting — `open -a <bogus name>` exits non-zero when the
    /// app doesn't exist, which is the only way to actually know the
    /// launch failed instead of assuming success just because the
    /// process started. `open` hands off to LaunchServices and returns
    /// almost immediately, so this doesn't wait for the target app to
    /// finish launching.
    @discardableResult
    private static func openApp(named name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        do {
            try process.run()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            NSLog("Sayline: agent opened app -> \(name) (success: \(succeeded))")
            return succeeded
        } catch {
            NSLog("Sayline: agent failed to open app \(name) -> \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private static func findFile(query: String, in folder: AgentAction.SearchFolder, subpath: String?) -> Bool {
        if searchOnce(query: query, in: folder, subpath: subpath) {
            return true
        }

        // The system call that triggers a folder-permission dialog
        // (Desktop/Documents/Downloads) doesn't retroactively succeed
        // just because the user clicked Allow — the *next* call does.
        // Found live: a first-ever request into a fresh folder failed
        // even after granting access, and only the following identical
        // request worked. One silent retry absorbs that macOS TCC quirk
        // instead of leaving a user's very first request looking broken
        // for a reason that has nothing to do with whether the file
        // actually exists.
        NSLog("Sayline: agent search came up empty, retrying once")
        if searchOnce(query: query, in: folder, subpath: subpath) {
            return true
        }

        NSLog("Sayline: agent found no file matching \"\(query)\" in \(folder.rawValue) or any other known folder, even after retry")
        return false
    }

    private static func searchOnce(query: String, in folder: AgentAction.SearchFolder, subpath: String?) -> Bool {
        if let match = bestMatch(for: query, in: folder, subpath: subpath) {
            NSLog("Sayline: agent found file -> \(match.path)")
            NSWorkspace.shared.activateFileViewerSelecting([match])
            return true
        }

        // The model has to guess a folder when the user doesn't name
        // one, and that guess is a semantic hunch, not real knowledge of
        // where the file lives — found live that "find meeting notes"
        // guessed Documents when the file was actually sitting in
        // Downloads, forcing a second, more specific request. Falling
        // back across the other known folders avoids making the user
        // re-specify every time the guess is wrong. Subpath is deliberately
        // not carried into the fallback folders — it was scoped to the
        // originally-named folder, not a hint about the others.
        //
        // .home is deliberately excluded here — it's a recursive walk of
        // the entire home directory (Library and everything else in it),
        // which is slow and would fire a permission prompt for every
        // protected subfolder it touches. Only try it if the user names
        // it explicitly, not as a silent fallback.
        let fallbackFolders = AgentAction.SearchFolder.allCases.filter { $0 != folder && $0 != .home }
        var fallbackCandidates: [(url: URL, modified: Date)] = []
        for fallbackFolder in fallbackFolders {
            fallbackCandidates += candidates(for: query, in: fallbackFolder, subpath: nil)
        }

        guard let match = fallbackCandidates.max(by: { $0.modified < $1.modified }) else {
            return false
        }

        NSLog("Sayline: agent found file in fallback folder -> \(match.url.path)")
        NSWorkspace.shared.activateFileViewerSelecting([match.url])
        return true
    }

    private static func bestMatch(for query: String, in folder: AgentAction.SearchFolder, subpath: String?) -> URL? {
        let matches = candidates(for: query, in: folder, subpath: subpath)
        // Prefer the most recently modified match — matches what "latest"/
        // "by date modified" actually means, and gives a sensible default
        // when multiple files match (found live: a folder had more than
        // one resume-like file; picking arbitrarily returned the wrong
        // one on some runs).
        return matches.max(by: { $0.modified < $1.modified })?.url
    }

    private static func candidates(
        for query: String, in folder: AgentAction.SearchFolder, subpath: String?
    ) -> [(url: URL, modified: Date)] {
        guard let folderURL = resolvedURL(for: folder, subpath: subpath),
              let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        // Match on individual words, not the query as one literal phrase —
        // found live that "resume PDF" (query) failed to match
        // "Shweta_Resume.pdf" (filename) purely because of a space vs a
        // period, even though a human would obviously call that a match.
        let queryWords = query.lowercased().split(separator: " ").map(String.init)

        var results: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            guard queryWords.allSatisfy({ name.contains($0) }) else { continue }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            results.append((fileURL, modified))
        }
        return results
    }

    private static func url(for folder: AgentAction.SearchFolder) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch folder {
        case .downloads: return home.appendingPathComponent("Downloads")
        case .documents: return home.appendingPathComponent("Documents")
        case .desktop: return home.appendingPathComponent("Desktop")
        case .home: return home
        }
    }

    /// Appends an optional nested subpath onto one of the four known
    /// roots — lets requests like "open the Codex folder inside
    /// Documents" resolve to Documents/Codex instead of just Documents,
    /// which the fixed SearchFolder enum alone can't express. Path
    /// components are filtered (no "..", no empty segments) so this can
    /// never resolve outside the chosen root.
    private static func resolvedURL(for folder: AgentAction.SearchFolder, subpath: String?) -> URL? {
        guard let base = url(for: folder) else { return nil }
        guard let subpath, !subpath.isEmpty else { return base }
        let safeComponents = subpath
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
        return safeComponents.reduce(base) { $0.appendingPathComponent($1) }
    }
}
