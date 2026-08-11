import Foundation

/// Every log line, kept on disk where a user can find it.
///
/// Three freeze investigations have now died at the same wall: when it
/// happens, there is no record. `NSLog` reaches a human only if the app was
/// launched from a terminal with a stderr redirect, which is a developer's
/// workflow and not anybody else's — so the one session that actually
/// froze is always the session without logs. The fourth incident on
/// 2026-08-11 was only diagnosable at all because a redirect happened to be
/// running.
///
/// Writes are asynchronous on a serial queue, deliberately. The tap thread
/// logs from inside its callback, and a synchronous file write there could
/// cause the very timeout being investigated. The cost is that a hard kill
/// can lose the last few milliseconds; the events worth catching unfold
/// over tens of seconds, so that trade is fine.
enum SaylineLog {
    private static let queue = DispatchQueue(label: "com.abhishektigga.sayline.log")
    private static let maxBytes = 2 * 1024 * 1024

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Sayline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var fileURL: URL { directory.appendingPathComponent("sayline.log") }
    private static var previousURL: URL { directory.appendingPathComponent("sayline.previous.log") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Logs to the console and to the file. Call it exactly where `NSLog`
    /// used to be; the "Sayline: " prefix is added here so call sites stay
    /// short and the file stays greppable.
    static func log(_ message: String) {
        NSLog("%@", "Sayline: \(message)")
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default

        // Rotate before writing rather than after, so the cap is a cap
        // rather than a suggestion. One previous file is kept: a freeze
        // usually gets reported after the fact, and the session before the
        // relaunch is the one that matters.
        if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           size > maxBytes {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: fileURL, to: previousURL)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Written at launch so every session in the file is separable, and so
    /// a report says which build produced it.
    static func startSession() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("──── session start · Sayline \(version) (\(build)) · macOS "
            + "\(ProcessInfo.processInfo.operatingSystemVersionString) ────")
        log("log file: \(fileURL.path)")
    }
}
