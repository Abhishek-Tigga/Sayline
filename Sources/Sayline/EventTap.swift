import Cocoa

/// One CGEventTap and its bookkeeping: creation on the current thread's
/// run loop, health accounting, enable/disable, teardown.
///
/// Exists because of the two-tap split (2026-08-14, the freeze fix).
/// macOS holds keyboard delivery for an active (`.defaultTap`) tap until
/// its callback answers, and a slow answer is how a keyboard freezes. A
/// `.listenOnly` tap gets a copy of events *after* delivery — nothing
/// ever waits on it, so it cannot freeze anything no matter how slow its
/// callback gets. The permanent hotkey tap is listen-only; the one
/// active tap left in the app lives only for the seconds a hold lasts.
/// Both are this class — the dangerous variant is one visible
/// constructor argument.
final class EventTap {
    /// Mach ticks to nanoseconds. Computed once; the ratio never changes
    /// for the life of the process.
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private let label: String
    private let options: CGEventTapOptions
    private let mask: CGEventMask
    /// The gesture logic. Return nil to swallow the event — honored only
    /// for active taps; the system ignores a listen-only tap's return
    /// value.
    private let handler: (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    /// The system disabled this tap (timeout or user input). Called on
    /// the tap's thread. The owner decides policy — this class never
    /// re-enables on its own, so there is exactly one place per tap that
    /// calls `enable`, which is the rule the 24,884-iteration loop of
    /// 2026-08-13 was fixed by.
    var onDisabled: ((CGEventType) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Tap health
    //
    // All written in the callback and read on the same thread. No
    // locking, and none should be added without checking that still
    // holds. These exist because `tapDisabledByTimeout` means "your
    // callback took too long" and this project spent two days of freeze
    // analysis never knowing what its callback cost.
    private var callbackCount = 0
    private var lastCallbackMillis = 0.0
    private var worstCallbackMillis = 0.0
    private var lastDeliveryLagMillis = 0.0
    private var worstDeliveryLagMillis = 0.0
    private var lastLagWarning = Date.distantPast

    /// One line describing how well this tap is being serviced, for any
    /// log that needs it. Cheap enough to build on a disable.
    var health: String {
        String(format: "callback last %.1fms worst %.1fms over %d events; "
                     + "delivery lag last %.0fms worst %.0fms",
               lastCallbackMillis, worstCallbackMillis, callbackCount,
               lastDeliveryLagMillis, worstDeliveryLagMillis)
    }

    var isInstalled: Bool { tap != nil }

    init(label: String, options: CGEventTapOptions, mask: CGEventMask,
         handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
        self.label = label
        self.options = options
        self.mask = mask
        self.handler = handler
    }

    /// Creates the tap and adds it to the *current* thread's run loop —
    /// call only on the thread that will service it.
    @discardableResult
    func install() -> Bool {
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.dispatch(type: type, event: event)
            },
            userInfo: selfPointer
        ) else {
            return false
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Removes the tap from the run loop it was installed on — call on
    /// that same thread. The port is invalidated so a torn-down tap
    /// cannot linger half-alive.
    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func disable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func dispatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onDisabled?(type)
            return Unmanaged.passUnretained(event)
        }
        // Measured around every callback, because the number macOS acts
        // on is how long we take to answer.
        let began = DispatchTime.now().uptimeNanoseconds
        let result = handler(type, event)
        recordDelivery(event: event,
                       spentNanos: DispatchTime.now().uptimeNanoseconds - began)
        return result
    }

    /// Records what one callback cost, and how stale the event already
    /// was when it arrived.
    ///
    /// The lag is the interesting half: if delivery backs up before a
    /// disable, the problem is in this process; if lag stays flat, the
    /// refusal came from outside. This distinction is what the whole
    /// freeze investigation was missing.
    private func recordDelivery(event: CGEvent, spentNanos: UInt64) {
        let spent = Double(spentNanos) / 1_000_000
        callbackCount += 1
        lastCallbackMillis = spent
        worstCallbackMillis = max(worstCallbackMillis, spent)

        let timebase = Self.machTimebase
        let now = mach_absolute_time()
        let created = event.timestamp
        guard timebase.denom != 0, now > created else { return }
        let lag = Double(now - created) * Double(timebase.numer)
                / Double(timebase.denom) / 1_000_000
        lastDeliveryLagMillis = lag
        worstDeliveryLagMillis = max(worstDeliveryLagMillis, lag)

        // Rate-limited: a backed-up queue produces many late events at
        // once, and a log line per event would itself slow the callback
        // down — turning the diagnostic into the disease.
        if lag > 250, Date().timeIntervalSince(lastLagWarning) > 5 {
            lastLagWarning = Date()
            SaylineLog.log(String(format:
                "%@ tap event arrived %.0fms late — delivery is backing up (%@)",
                label, lag, StallWatchdog.shared.snapshot))
        }
    }
}
