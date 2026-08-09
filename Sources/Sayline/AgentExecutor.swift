import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.ps

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
        case .openSystemSetting(let paneName, let bundleID):
            return openSystemSetting(paneName: paneName, bundleID: bundleID)
        case .openSystemSettingsFallback(let requestedPaneName):
            return openSystemSettingsFallback(requestedPaneName: requestedPaneName)
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
        case .openWebsite(let label, let url):
            return openWebsite(label: label, url: url)
        case .openedSiteButCouldNotSearch(let label, let url, let query):
            NSLog("%@", "Sayline: no search URL for \(label) — opened it and dropped the query \"\(query)\"")
            return openWebsite(label: label, url: url)
        case .unknownWebsite(let requested):
            // Handled visibly in AppDelegate, which flashes the "say the
            // full address" hint. Nothing to do here but report failure.
            NSLog("Sayline: agent doesn't know the site \"\(requested)\" and won't guess a domain")
            return false
        case .openDirectPage(let url, _, _):
            // AgentRouter verifies and replaces this before execution;
            // reaching here means the check was skipped.
            return openWebsite(label: url.host ?? "page", url: url)
        case .playOnYouTube(let query):
            // AgentRouter resolves this into .openWebsite before execution,
            // so reaching here means the lookup was skipped entirely. Open
            // the search page rather than doing nothing.
            let fallback = WebsiteCatalog.resolve("YouTube", query: query)
            if case .site(let label, let url) = fallback {
                return openWebsite(label: label, url: url)
            }
            return false
        case .answerQuery(let query):
            // The normal path for this is AppDelegate special-casing
            // .answerQuery before calling execute() at all, so it can
            // display the answer — this branch only exists so the
            // switch stays exhaustive if execute() is ever called
            // directly with a query action.
            NSLog("Sayline: agent answered -> \(answer(query))")
            return true
        }
    }

    /// Produces a displayable fact rather than performing a side effect
    /// — deliberately no second LLM call to phrase these. Once we have
    /// the real number, formatting it is just string templating; routing
    /// a known-correct fact back through an LLM to "say it nicely" would
    /// only add latency and a hallucination risk for zero benefit.
    static func answer(_ query: AgentAction.SystemQuery) -> String {
        switch query {
        case .battery: return batteryAnswer()
        case .storage: return storageAnswer()
        case .memory: return memoryAnswer()
        case .uptime: return uptimeAnswer()
        case .volumeLevel: return volumeLevelAnswer()
        case .macOSVersion: return macOSVersionAnswer()
        case .nowPlaying: return nowPlayingAnswer()
        }
    }

    private static func batteryAnswer() -> String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int else {
            return "Couldn't read battery status"
        }
        let isCharging = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return isCharging ? "Battery: \(capacity)% (charging)" : "Battery: \(capacity)%"
    }

    private static func storageAnswer() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]), let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else {
            return "Couldn't read storage info"
        }
        let availableGB = Double(available) / 1_000_000_000
        let totalGB = Double(total) / 1_000_000_000
        return String(format: "Storage: %.0f GB free of %.0f GB", availableGB, totalGB)
    }

    /// Mirrors Activity Monitor's rough "used" categorization
    /// (active + wired + compressed pages) rather than raw free pages,
    /// which alone is a misleading number on macOS due to aggressive
    /// disk caching.
    private static func memoryAnswer() -> String {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "Couldn't read memory info" }

        let pageSize = UInt64(vm_kernel_page_size)
        let used = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        let usedGB = Double(used) / 1_000_000_000
        let totalGB = Double(total) / 1_000_000_000
        return String(format: "Memory: %.1f GB used of %.1f GB", usedGB, totalGB)
    }

    private static func uptimeAnswer() -> String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "Uptime: \(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "Uptime: \(hours)h \(minutes)m"
        } else {
            return "Uptime: \(minutes)m"
        }
    }

    private static func volumeLevelAnswer() -> String {
        guard let script = NSAppleScript(source: "output volume of (get volume settings)") else {
            return "Couldn't read volume"
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return "Couldn't read volume" }
        return "Volume: \(result.int32Value)%"
    }

    private static func macOSVersionAnswer() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Checks Music.app and Spotify specifically via AppleScript, in
    /// that order, only if each is actually running (never launches
    /// them just to check). Deliberately not using the private
    /// MediaRemote framework third-party "now playing" tools rely on —
    /// undocumented, fragile across macOS versions, not worth the risk
    /// for this. First use will need a one-time Automation permission
    /// grant per app, same category as Dark Mode/Empty Trash.
    private static func nowPlayingAnswer() -> String {
        if isRunning("Music"), let info = currentTrack(app: "Music") {
            return info
        }
        if isRunning("Spotify"), let info = currentTrack(app: "Spotify") {
            return info
        }
        return "Nothing appears to be playing"
    }

    private static func isRunning(_ appName: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }
    }

    private static func currentTrack(app: String) -> String? {
        let script = """
        tell application "\(app)"
            if player state is playing then
                return (name of current track) & " — " & (artist of current track)
            else
                return "paused"
            end if
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue, value != "paused" else { return nil }
        return "Now Playing: \(value)"
    }

    /// Sends a normal terminate request (equivalent to Cmd+Q) rather than
    /// force-killing — respects the app's own unsaved-changes prompt
    /// instead of silently discarding work.
    ///
    /// Matching is normalized rather than exact, and falls back to the
    /// bundle identifier. Exact comparison against `localizedName` failed
    /// on WhatsApp every single time while "open WhatsApp" worked in the
    /// same breath — its localizedName is 9 characters, not 8, because the
    /// app prefixes its own name with U+200E LEFT-TO-RIGHT MARK. Invisible
    /// on screen, fatal to `==`. Opening was unaffected because `open -a`
    /// resolves through LaunchServices by app file, never touching the
    /// display name.
    @discardableResult
    private static func closeApp(named name: String) -> Bool {
        let target = normalizedAppName(name)
        let running = NSWorkspace.shared.runningApplications

        let app = running.first { normalizedAppName($0.localizedName ?? "") == target }
            // Bundle identifiers are stable and never carry display-name
            // decoration, so "whatsapp" still finds net.whatsapp.WhatsApp.
            ?? running.first { candidate in
                guard let bundleID = candidate.bundleIdentifier else { return false }
                return bundleID.split(separator: ".").contains { normalizedAppName(String($0)) == target }
            }

        guard let app else {
            let names = running
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
                .joined(separator: ", ")
            NSLog("Sayline: agent could not find a running app named \"\(name)\" to close — running: [\(names)]")
            return false
        }
        let didTerminate = app.terminate()
        NSLog("Sayline: agent closed app -> \(app.localizedName ?? name) (requested: \(didTerminate))")
        return didTerminate
    }

    /// Lowercased, letters and digits only. Strips whatever decoration an
    /// app puts in its display name — directional marks, spaces,
    /// punctuation — so comparison is on the part a person would say.
    private static func normalizedAppName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `bundleID` comes pre-resolved from the live `SettingsPaneCatalog`
    /// (see AgentRouter.parseAction) — no hardcoded identifier switch
    /// here anymore. Self-heals macOS version drift: the catalog is read
    /// from whatever's actually installed, so there's no hand-copied
    /// identifier left to go stale the way `.general`'s did before this
    /// rewrite (see BACKLOG.md, "Dynamic System Settings pane catalog").
    @discardableResult
    private static func openSystemSetting(paneName: String, bundleID: String) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:\(bundleID)") else { return false }
        let opened = NSWorkspace.shared.open(url)
        NSLog("Sayline: agent opened system setting -> \(paneName) [\(bundleID)] (success: \(opened))")
        return opened
    }

    /// Deliberately opens nothing. The first version of this did open
    /// System Settings via the bare `x-apple.systempreferences:` scheme,
    /// which restores whatever pane was last viewed — so asking for a
    /// pane we don't have surfaced an unrelated one (reported live
    /// 2026-08-09: "open general settings" opened Screen Time). A wrong
    /// pane reads as a wrong *answer*, which is worse than visibly doing
    /// nothing; the flash message from AppDelegate is the whole response
    /// now. Returns false so the caller reports it as a real failure.
    @discardableResult
    private static func openSystemSettingsFallback(requestedPaneName: String) -> Bool {
        NSLog("Sayline: agent could not match settings pane \"\(requestedPaneName)\" in the catalog — doing nothing, flashing a message instead")
        return false
    }

    /// Opens in the user's default browser. Named-browser routing ("open
    /// x in Chrome") is deliberately not here yet — it needs its own tool
    /// parameter, and the default covers the common case.
    @discardableResult
    private static func openWebsite(label: String, url: URL) -> Bool {
        let opened = NSWorkspace.shared.open(url)
        NSLog("%@", "Sayline: agent opened website -> \(label) \(url.absoluteString) (success: \(opened))")
        return opened
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
