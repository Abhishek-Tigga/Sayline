import AppKit
import Foundation

enum AgentExecutor {
    static func execute(_ action: AgentAction) {
        switch action {
        case .openApp(let name):
            openApp(named: name)
        case .findFile(let query, let folder):
            findFile(query: query, in: folder)
        }
    }

    private static func openApp(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        do {
            try process.run()
            NSLog("Sayline: agent opened app -> \(name)")
        } catch {
            NSLog("Sayline: agent failed to open app \(name) -> \(error.localizedDescription)")
        }
    }

    private static func findFile(query: String, in folder: AgentAction.SearchFolder) {
        guard let folderURL = url(for: folder) else {
            NSLog("Sayline: agent could not resolve folder \(folder.rawValue)")
            return
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            NSLog("Sayline: agent could not enumerate \(folderURL.path)")
            return
        }

        // Match on individual words, not the query as one literal phrase —
        // found live that "resume PDF" (query) failed to match
        // "Shweta_Resume.pdf" (filename) purely because of a space vs a
        // period, even though a human would obviously call that a match.
        let queryWords = query.lowercased().split(separator: " ").map(String.init)

        var candidates: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            guard queryWords.allSatisfy({ name.contains($0) }) else { continue }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((fileURL, modified))
        }

        // Prefer the most recently modified match — matches what "latest"/
        // "by date modified" actually means, and gives a sensible default
        // when multiple files match (found live: this folder has more
        // than one resume-like file; picking arbitrarily returned the
        // wrong one on some runs).
        guard let match = candidates.max(by: { $0.modified < $1.modified }) else {
            NSLog("Sayline: agent found no file matching \"\(query)\" in \(folder.rawValue)")
            return
        }

        NSLog("Sayline: agent found file (\(candidates.count) match(es), newest picked) -> \(match.url.path)")
        NSWorkspace.shared.activateFileViewerSelecting([match.url])
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
}
