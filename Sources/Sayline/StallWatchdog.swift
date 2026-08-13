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

    /// The tap thread's own heartbeat, and why it exists.
    ///
    /// Fable, 2026-08-14: every freeze conclusion drawn from "main ok 0.0s"
    /// beside a tap disable was drawn from the wrong thread. This watchdog
    /// measured the main thread only. The event tap runs on its own thread,
    /// which nothing watched — so a healthy main thread said nothing at all
    /// about whether the tap was being serviced. The heartbeat could not
    /// see tap starvation by construction, which is exactly the mechanism
    /// now suspected.
    ///
    /// nil until the tap thread starts, so a machine without Accessibility
    /// granted does not report a permanently stalled tap that does not
    /// exist.
    private var lastTapBeat: Date?
    private var tapStallStarted: Date?
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
        checker.setEventHandler { [weak self] in self?.check() }
        checker.resume()
        self.checker = checker
        SaylineLog.log("stall watchdog started — main + tap heartbeats, check 0.5s, threshold \(Int(threshold))s")
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

    /// Stamped by the tap thread on every run-loop slice, so roughly every
    /// 250ms. If this goes quiet the tap is not being serviced, which is
    /// the condition macOS disables a tap for.
    func tapBeat() {
        lock.lock()
        let wasStalledFor = tapStallStarted.map { Date().timeIntervalSince($0) }
        lastTapBeat = Date()
        tapStallStarted = nil
        lock.unlock()

        if let wasStalledFor, wasStalledFor >= threshold {
            SaylineLog.log(String(format: "tap thread came back after %.1fs", wasStalledFor))
        }
    }

    /// How long the main thread has been silent. Safe from any thread.
    var mainThreadSilence: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBeat)
    }

    /// How long the tap thread has been silent, or nil if it never started.
    var tapThreadSilence: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastTapBeat.map { Date().timeIntervalSince($0) }
    }

    /// Checks both threads. Called from the tap thread between run-loop
    /// slices *and* from this class's own timer — the timer is what matters
    /// for the tap, since a stalled tap thread cannot report itself.
    ///
    /// Each stall is logged once when it starts, not every pass.
    func check() {
        checkMain()
        checkTap()
    }

    private func checkMain() {
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

    private func checkTap() {
        guard let silence = tapThreadSilence, silence >= threshold else { return }

        lock.lock()
        let alreadyReported = tapStallStarted != nil
        if !alreadyReported { tapStallStarted = Date().addingTimeInterval(-silence) }
        lock.unlock()

        if !alreadyReported {
            SaylineLog.log(String(format:
                "TAP THREAD STALLED — no heartbeat for %.1fs (the tap is not being serviced)", silence))
        }
    }

    /// A one-line description for other log lines to carry, so an event and
    /// both threads' states at that instant sit on the same line.
    ///
    /// Carries the tap thread as well as main. A disable logged with only
    /// main's state is the evidence that misled this project for two days.
    var snapshot: String {
        let main = mainThreadSilence
        let mainPart = main >= threshold
            ? String(format: "main STALLED %.1fs", main)
            : String(format: "main ok %.1fs", main)
        guard let tap = tapThreadSilence else { return mainPart + ", tap thread not started" }
        let tapPart = tap >= threshold
            ? String(format: "tap STALLED %.1fs", tap)
            : String(format: "tap ok %.1fs", tap)
        return mainPart + ", " + tapPart
    }
}
