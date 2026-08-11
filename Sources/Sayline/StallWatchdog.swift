import Foundation

/// Watches whether the main thread is still answering.
///
/// Built after the fourth freeze on 2026-08-11, which the third theory
/// explicitly did not cover: the tap was enabled, secure input was off, and
/// macOS timed the tap out seven times in 96 seconds while the user's
/// keyboard stopped responding.
///
/// `kCGEventTapDisabledByTimeout` canonically means "your callback took too
/// long". Our callback does almost nothing — unless it is waiting on
/// something. Whether the main thread was alive at that exact moment is the
/// single fact that separates the two remaining explanations, and no
/// investigation so far has had it:
///
/// - **Main alive when the tap is disabled** → our callback is not blocked
///   by the app, and the system is refusing the tap for a reason outside
///   this process. Look outward.
/// - **Main stalled at the same moment** → something on the main thread is
///   holding the callback, and it is ours to find. Look inward.
///
/// Deliberately simple. The main thread stamps a timestamp once a second;
/// the tap thread, which already wakes every 250ms, reads it. No new
/// threads, no polling loop of its own — a diagnostic that adds load is a
/// diagnostic that changes what it measures.
final class StallWatchdog {
    static let shared = StallWatchdog()

    private let lock = NSLock()
    private var lastBeat = Date()
    private var stallStarted: Date?
    private var timer: Timer?
    /// Its own background timer rather than borrowing the tap thread's
    /// loop. The first version rode on that loop, which does not run until
    /// the event tap installs — so on a machine without Accessibility
    /// granted the watchdog silently did nothing, and a diagnostic that
    /// depends on the subsystem it diagnoses is not a diagnostic.
    private var checker: DispatchSourceTimer?

    /// How long main may be silent before it counts as stalled. A second
    /// covers ordinary main-thread work; two means something is wrong.
    private let threshold: TimeInterval = 2

    private init() {}

    /// Starts the heartbeat. Main thread only.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.beat()
        }
        // Common modes so a menu tracking loop or a window drag does not
        // silence the heartbeat and fake a stall.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        beat()

        let checker = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.abhishektigga.sayline.watchdog", qos: .utility)
        )
        checker.schedule(deadline: .now() + 1, repeating: 0.5)
        checker.setEventHandler { [weak self] in self?.checkFromBackgroundThread() }
        checker.resume()
        self.checker = checker
        SaylineLog.log("stall watchdog started — main heartbeat 1s, check 0.5s, threshold \(Int(threshold))s")
    }

    private func beat() {
        lock.lock()
        let wasStalledFor = stallStarted.map { Date().timeIntervalSince($0) }
        lastBeat = Date()
        stallStarted = nil
        lock.unlock()

        if let wasStalledFor, wasStalledFor >= threshold {
            SaylineLog.log(String(format: "main thread came back after %.1fs", wasStalledFor))
        }
    }

    /// How long the main thread has been silent. Safe from any thread.
    var mainThreadSilence: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBeat)
    }

    /// Called from the tap thread between run-loop slices. Logs the moment
    /// a stall starts, once, rather than every 250ms.
    func checkFromBackgroundThread() {
        let silence = mainThreadSilence
        guard silence >= threshold else { return }

        lock.lock()
        let alreadyReported = stallStarted != nil
        if !alreadyReported { stallStarted = Date().addingTimeInterval(-silence) }
        lock.unlock()

        if !alreadyReported {
            SaylineLog.log(String(format: "MAIN THREAD STALLED — no heartbeat for %.1fs", silence))
        }
    }

    /// A one-line description for other log lines to carry, so an event and
    /// the main thread's state at that instant sit on the same line.
    var snapshot: String {
        let silence = mainThreadSilence
        return silence >= threshold
            ? String(format: "main STALLED %.1fs", silence)
            : String(format: "main ok %.1fs", silence)
    }
}
