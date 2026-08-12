import AVFoundation
import CoreAudio

/// Records microphone audio to a temp .wav file for the duration of a tap-hold.
final class AudioRecorder {
    /// Every call into `AVAudioEngine` happens here, never on main.
    ///
    /// `outputFormat(forBus:)` is a `dispatch_sync` onto AVFAudio's own
    /// internal queue. On 2026-08-12 that queue was servicing a hardware
    /// property listener stuck in a mach round trip to `coreaudiod`, and
    /// the main thread waited on it permanently: menu bar dead, hotkey
    /// dead, 33% CPU, captured in a `sample` stack.
    ///
    /// This is very likely the freeze recorded in CLAUDE.md as four
    /// incidents with three disproven theories. A wedged main thread stops
    /// the app servicing its event tap, macOS disables the tap with
    /// `kCGEventTapDisabledByTimeout`, and the keyboard dies until Sayline
    /// is killed — which is exactly what was reported each time.
    ///
    /// The machine that produced it had a duplicated Bluetooth device, a
    /// Continuity microphone and a virtual driver installed. We cannot
    /// stop macOS churning its device list; we can refuse to block the
    /// main thread on it.
    private let audioQueue = DispatchQueue(label: "com.abhishektigga.sayline.audio")
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?
    private var recordingStartTime: Date?
    private(set) var lastRecordingDuration: TimeInterval = 0
    /// Frames the tap actually wrote. Zero means the device accepted the
    /// engine but never delivered audio — see `capturedNoAudio`.
    private var framesWritten: AVAudioFramePosition = 0
    /// Diagnostics for the 2026-08-12 zero-frame bug. Remove with the
    /// [mic] log lines once the cause is known.
    private var tapCallbacks = 0
    private var firstBufferLogged = false
    /// Set once — voice processing belongs to the node, not the recording.
    private var voiceProcessingEnabled = false
    /// Name of the device the engine really used, read after `start()`.
    private(set) var lastInputDeviceName = "unknown"

    /// True when a recording ran its full length and captured nothing at
    /// all. A Bluetooth speaker being the system default input does this:
    /// it is a valid device, the engine starts happily, the tap never
    /// fires. Worth separating from silence — silence is a quiet room,
    /// this is a broken input, and only one of them is worth telling the
    /// user about.
    var capturedNoAudio: Bool { framesWritten == 0 && lastRecordingDuration >= 0.4 }

    /// Loudest sample in the last recording, set by `isTooShortOrSilent()`.
    /// Kept so the transcript stage can tell a real "thank you" from one
    /// Whisper invented out of silence — see `WhisperHallucination`.
    private(set) var lastRecordingPeak: Float = 0

    /// Deletes the finished recording.
    ///
    /// Nothing did this until 2026-08-11, and by then 390 files totalling
    /// 514 MB had accumulated on the developer's own machine — a rolling
    /// archive of every word ever spoken into the app, unencrypted, in a
    /// directory macOS only clears sporadically. For a product whose pitch
    /// includes privacy that is not a bug, it is the story.
    ///
    /// Callers invoke this when transcription finishes, success or failure.
    /// `start()` also clears the previous file, so a caller that forgets
    /// leaks exactly one recording until the next hold rather than all of
    /// them — the lifecycle belongs to whoever creates the file, not to
    /// whoever happens to consume it.
    func discardLastRecording() {
        guard let url = lastRecordingURL else { return }
        lastRecordingURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Clears recordings left behind by a crash, or by every version before
    /// this one. Runs at launch; failures are ignored because a file we
    /// cannot delete is not worth blocking startup over.
    static func sweepOrphanedRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: nil
        ) else { return }
        let orphans = files.filter {
            $0.lastPathComponent.hasPrefix("sayline-") && $0.pathExtension == "wav"
        }
        guard !orphans.isEmpty else { return }
        for url in orphans { try? fm.removeItem(at: url) }
        SaylineLog.log("swept \(orphans.count) leftover recording(s) from previous runs")
    }

    /// The live answer, not a cached one.
    ///
    /// The launch-time check goes stale the moment someone changes the
    /// setting in System Settings — and after a rebuild it is stale
    /// immediately, because the new signature loses the grant. On
    /// 2026-08-12 that produced three recordings of pure silence, each
    /// reported as "check the input device", while the microphone was
    /// perfectly fine and simply not permitted.
    static var micAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// `preferredDeviceUID`: nil follows the system default input device
    /// (which AVAudioEngine already tracks automatically — verified live
    /// that it picks up newly connected AirPods with zero extra code). A
    /// non-nil UID pins recording to that specific device regardless of
    /// whatever macOS currently considers default.
    /// Starts recording. **Never touches the audio engine on the calling
    /// thread** — see `audioQueue`.
    ///
    /// `completion` runs on the main thread once the engine is up, with
    /// `true` when it actually started.
    func start(preferredDeviceUID: String? = nil, completion: @escaping (Bool) -> Void) {
        guard !isRecording else { completion(false); return }
        // Claimed on the caller's thread (main) so a second hold cannot
        // race in behind this one while the engine is still coming up.
        isRecording = true
        audioQueue.async { [weak self] in
            let started = self?.startOnAudioQueue(preferredDeviceUID: preferredDeviceUID) ?? false
            DispatchQueue.main.async {
                if !started { self?.isRecording = false }
                completion(started)
            }
        }
    }

    /// Turns on Apple's voice processing: echo cancellation plus noise
    /// suppression, the same path FaceTime uses.
    ///
    /// This is what stops dictation transcribing whatever the speakers are
    /// playing. Sound from the built-in speakers reaches the built-in
    /// microphone, and Whisper cannot tell a lyric from a sentence — a
    /// YouTube track was transcribed as if the user had said it.
    ///
    /// The first attempt at this paused the user's music for the length of
    /// each hold. It worked and it was hated, correctly: silencing someone's
    /// music every time they dictate is a worse experience than the problem
    /// it solved. Cancelling the speaker out of the signal fixes the same
    /// thing while the music keeps playing.
    ///
    /// Measured on this Mac before shipping it, speaker audio only: peak
    /// **0.8085 without, 0.0230 with** — a 97% reduction.
    ///
    /// Set once per node, before the engine starts. Failure is not fatal:
    /// a recording with echo in it beats no recording at all.
    private func enableVoiceProcessing(on input: AVAudioInputNode) {
        guard !voiceProcessingEnabled else { return }
        do {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingEnabled = true
            SaylineLog.log("voice processing enabled — speaker audio cancelled from the mic")
        } catch {
            // Some devices and aggregate configurations refuse it. Carry on
            // unprocessed rather than losing the hold.
            SaylineLog.log("voice processing unavailable (\(error.localizedDescription)) — recording raw")
        }
    }

    private func startOnAudioQueue(preferredDeviceUID: String?) -> Bool {
        // Safety net for the lifecycle above: even if a consumer forgot to
        // discard, the previous recording dies here.
        discardLastRecording()

        let input = engine.inputNode

        if let preferredDeviceUID, let deviceID = AudioDeviceLister.deviceID(forUID: preferredDeviceUID) {
            setInputDevice(deviceID, on: input)
        }

        enableVoiceProcessing(on: input)

        // Read AFTER voice processing is enabled. Turning it on replaces the
        // input format — 16 kHz became 48 kHz in testing — so a format read
        // first would describe a graph that no longer exists.
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayline-\(UUID().uuidString).wav")

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            SaylineLog.log("failed to create audio file: \(error)")
            return false
        }

        framesWritten = 0
        // Temporary diagnostics for the zero-frame bug of 2026-08-12, where
        // every recording produced frames: 0 while an independent
        // AVAudioEngine in another process captured 48000 in three seconds
        // on the same device. The question these answer is the one the log
        // could not: does the tap fire at all, and if so with what?
        tapCallbacks = 0
        firstBufferLogged = false
        SaylineLog.log("[mic] engine.isRunning before start: \(engine.isRunning), "
            + "format \(format.sampleRate)Hz \(format.channelCount)ch, "
            + "inputNode format \(input.inputFormat(forBus: 0).sampleRate)Hz")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.tapCallbacks += 1
            if !self.firstBufferLogged {
                self.firstBufferLogged = true
                var peak: Float = 0
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
                }
                SaylineLog.log("[mic] first tap buffer: \(buffer.frameLength) frames, peak \(peak), "
                    + "file \(self.audioFile == nil ? "MISSING" : "ready")")
            }
            guard let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
                self.framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                SaylineLog.log("failed writing audio buffer: \(error)")
            }
        }

        do {
            try engine.start()
            lastRecordingURL = url
            recordingStartTime = Date()
            // Read after start, not before. Before the engine runs, the audio
            // unit still reports whatever device it was initialised with, so
            // the log claimed "MacBook Air Microphone" while the engine was
            // actually on a Bluetooth device. Logging the format too, because
            // 16 kHz on a device that should do 48 kHz is the tell.
            lastInputDeviceName = currentInputDeviceName()
            SaylineLog.log("recording started on \(lastInputDeviceName) at \(Int(format.sampleRate)) Hz -> \(url.path)")
            return true
        } catch {
            SaylineLog.log("failed to start audio engine: \(error)")
            input.removeTap(onBus: 0)
            audioFile = nil
            return false
        }
    }

    /// Stops recording. `completion` runs on main once the engine is down
    /// and `lastRecordingURL`, `capturedNoAudio` and the rest are settled —
    /// read them there, not immediately after calling this.
    func stop(completion: @escaping () -> Void) {
        guard isRecording else { completion(); return }
        isRecording = false
        audioQueue.async { [weak self] in
            self?.stopOnAudioQueue()
            DispatchQueue.main.async { completion() }
        }
    }

    private func stopOnAudioQueue() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        lastRecordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        SaylineLog.log("recording stopped -> \(lastRecordingURL?.path ?? "?") duration: \(lastRecordingDuration)s frames: \(framesWritten)")
        SaylineLog.log("[mic] tap fired \(tapCallbacks) time(s) during that recording")
    }

    /// True only if the just-finished recording is an accidental hotkey tap
    /// rather than speech. Exists because Whisper hallucinates filler
    /// phrases ("Thank you.", ".") on near-silent audio, which showed up as
    /// junk pastes in the history log.
    ///
    /// Rewritten 2026-08-09 after the first version silently ate real
    /// dictation — the log showed 6s, 8s and 11s recordings all rejected as
    /// "too short/silent". Two mistakes, both now fixed:
    ///
    /// 1. It averaged loudness (RMS) across the whole file. Natural pauses
    ///    between words drag that average down, so a long sentence with
    ///    gaps scored lower than a short continuous one. Peak amplitude is
    ///    the right measure: it asks "was there ever real sound here",
    ///    which is the actual question, and pauses can't dilute it.
    /// 2. Every failure path returned `true`, i.e. "throw it away". A check
    ///    that cannot make up its mind must fail open — a wasted API call
    ///    is cheap, silently binning what someone just said is not.
    func isTooShortOrSilent() -> Bool {
        // A hold this brief is a mis-tap, not a word.
        if lastRecordingDuration < 0.4 {
            SaylineLog.log("recording \(lastRecordingDuration)s — too short to be speech, skipping")
            return true
        }

        guard let url = lastRecordingURL,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            SaylineLog.log("couldn't measure audio level — transcribing anyway")
            lastRecordingPeak = 0
            return false // fail open
        }

        let samples = channelData[0]
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[i]))
        }
        lastRecordingPeak = peak

        // Deliberately generous. Room tone and mic self-noise peak around
        // 0.001–0.005; even quiet speech peaks well above 0.05. Logged so
        // the threshold can be tuned against real numbers instead of guesses.
        let isSilent = peak < 0.01
        SaylineLog.log("audio peak \(peak) over \(lastRecordingDuration)s -> \(isSilent ? "silent, skipping" : "has speech")")
        return isSilent
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) {
        guard let audioUnit = node.audioUnit else {
            SaylineLog.log("no audio unit available to set preferred input device")
            return
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            SaylineLog.log("failed to set preferred input device -> status \(status)")
        }
    }

    /// Reads whatever the input node's audio unit is *actually* using —
    /// reflects a pinned device if one was just set via setInputDevice,
    /// otherwise whatever it inherited from the system default.
    private func currentInputDeviceName() -> String {
        guard let audioUnit = engine.inputNode.audioUnit else { return "unknown (no audio unit)" }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size
        )
        guard status == noErr else { return "unknown (status \(status))" }

        return AudioDeviceLister.name(forDeviceID: deviceID) ?? "unknown (id \(deviceID))"
    }
}
