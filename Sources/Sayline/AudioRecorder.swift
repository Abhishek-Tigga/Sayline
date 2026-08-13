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
    /// Set when voice processing has already broken the engine once this
    /// session, so later holds do not each pay a failed start to rediscover
    /// it. Session-scoped rather than persisted: unplugging the display or
    /// the virtual driver that caused it should get a fresh chance.
    private var voiceProcessingBroke = false
    /// The device currently pinned on the unit, so a pin is applied once
    /// rather than on every hold.
    private var appliedDeviceID: AudioDeviceID?
    /// Converts the hardware format down to what Whisper actually wants.
    private var converter: AVAudioConverter?
    /// Set by AVAudioEngineConfigurationChange — the device list moved
    /// under us, so the next hold rebuilds rather than trusting the graph.
    private var configurationChanged = false
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
    /// Deletes a specific recording.
    ///
    /// Keyed to the URL the caller owns, never to "the last one". A hold
    /// that begins while the previous hold's transcription is still in
    /// flight moves `lastRecordingURL` — so the older transcription's
    /// deferred cleanup would delete the *new* recording out from under it.
    /// Rare, silent, and it costs a take.
    func discardRecording(at url: URL?) {
        guard let url else { return }
        if url == lastRecordingURL { lastRecordingURL = nil }
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

    init() {
        // This Mac's device list demonstrably churns — a duplicated
        // Bluetooth device, a Continuity microphone, a virtual driver. When
        // it moves, the engine's graph can be stale in ways that show up as
        // silence rather than as an error. Note it and rebuild next hold.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async {
                self?.configurationChanged = true
                SaylineLog.log("[mic] audio configuration changed — next hold rebuilds the graph")
            }
        }
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

    /// Turns Apple's voice processing — echo cancellation plus noise
    /// suppression, the same path FaceTime uses — on or off.
    ///
    /// On, it stops dictation transcribing whatever the speakers are
    /// playing: sound from the built-in speakers reaches the built-in
    /// microphone and Whisper cannot tell a lyric from a sentence.
    /// Measured before shipping, speaker audio only: peak **0.8085
    /// without, 0.0230 with** — a 97% reduction.
    ///
    /// An earlier attempt at the same problem paused the user's music for
    /// the length of every hold. It worked and was rightly hated.
    ///
    /// It is not universally available, and the failure is not the one you
    /// would expect: enabling it can succeed and then break `engine.start()`
    /// one step later, because it couples the input to the output and some
    /// output devices present a layout it cannot initialise. `startOnAudioQueue`
    /// therefore treats it as an attempt, not a setting.
    private func setVoiceProcessing(_ enabled: Bool, on input: AVAudioInputNode) {
        guard voiceProcessingEnabled != enabled else { return }
        do {
            try input.setVoiceProcessingEnabled(enabled)
            voiceProcessingEnabled = enabled
            SaylineLog.log(enabled
                ? "voice processing enabled — speaker audio cancelled from the mic"
                : "voice processing turned off")
        } catch {
            SaylineLog.log("could not \(enabled ? "enable" : "disable") voice processing: \(error.localizedDescription)")
        }
    }

    /// Brings voice processing up **once**, at launch, off the hot path.
    ///
    /// It used to be toggled off and on inside every hold, to make device
    /// pinning safe. Measured cost of that dance: **1.1 seconds per hold**,
    /// during which the microphone is not listening — so a 1.6s hold
    /// captured 0.48s and the user's first words were simply gone. Worse,
    /// it was protecting a device-set call that is skipped on every hold,
    /// because the pinned device is already the system default.
    ///
    /// Enabled once and left alone. It survives `stop()`/`start()`, so
    /// holds two through five cost nothing.
    func warmUp() {
        audioQueue.async { [weak self] in
            guard let self, !self.voiceProcessingBroke else { return }
            let started = Date()
            self.setVoiceProcessing(true, on: self.engine.inputNode)
            SaylineLog.log(String(format: "[mic] warm-up took %.0f ms — later holds pay none of it",
                                  Date().timeIntervalSince(started) * 1000))
        }
    }

    private func startOnAudioQueue(preferredDeviceUID: String?) -> Bool {
        if !voiceProcessingBroke,
           attemptStart(preferredDeviceUID: preferredDeviceUID, withVoiceProcessing: true) {
            return true
        }
        guard !voiceProcessingBroke else {
            // Already known bad this session — go straight to the path that
            // works instead of failing once more to learn the same thing.
            return attemptStart(preferredDeviceUID: preferredDeviceUID, withVoiceProcessing: false)
        }
        voiceProcessingBroke = true
        // Voice processing turned on happily and then took the engine down
        // with it — measured 2026-08-13, error -10875 from the *output*
        // node with the input format reading `48000 Hz, 9ch` and the
        // hardware input reading `0 Hz`. Enabling it couples input to
        // output, and a multichannel output device (a monitor, a virtual
        // conferencing driver) can present a layout the voice-processing
        // unit cannot initialise.
        //
        // Echo in a recording is a small problem. No recording at all is a
        // dead app, which is what this shipped as. So: try it, and if the
        // engine will not run, run without it.
        SaylineLog.log("retrying without voice processing")
        return attemptStart(preferredDeviceUID: preferredDeviceUID, withVoiceProcessing: false)
    }

    private func attemptStart(preferredDeviceUID: String?, withVoiceProcessing: Bool) -> Bool {
        // A failed attempt leaves the graph half-configured; clear it so the
        // retry starts from the same place the first attempt did.
        engine.stop()
        engine.reset()
        if configurationChanged {
            // The device list moved since the last hold. Drop the pin we
            // think is applied, so it is re-established against the devices
            // that exist now rather than the ones that did.
            configurationChanged = false
            appliedDeviceID = nil
            SaylineLog.log("[mic] rebuilding after a configuration change")
        }

        let input = engine.inputNode

        // Device selection must happen on a *plain* input unit.
        //
        // Voice processing binds the node to a private aggregate device
        // (`CADefaultDeviceAggregate-<pid>-0` in the log). Setting
        // `kAudioOutputUnitProperty_CurrentDevice` on that fails with
        // -10851 and — the part that actually hurt — leaves the unit with
        // **no device at all**. It then starts happily, reports
        // "unknown (id 0)", and records silence. Measured 2026-08-13: two
        // holds worked, and every hold after the aggregate appeared
        // captured zero frames.
        // Only touched when the pin actually has to change. The off→on
        // dance is what truncated every recording; it now runs when a real
        // device change needs a plain unit to land on, and not otherwise.
        if deviceNeedsApplying(preferredDeviceUID) {
            setVoiceProcessing(false, on: input)
            applyPreferredDevice(preferredDeviceUID, on: input)
        }
        setVoiceProcessing(withVoiceProcessing, on: input)

        // Read AFTER voice processing is enabled. Turning it on replaces the
        // input format — 16 kHz became 48 kHz in testing — so a format read
        // first would describe a graph that no longer exists.
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayline-\(UUID().uuidString).wav")

        // Whisper wants 16 kHz mono, and voice processing hands us 48 kHz
        // multichannel float. Writing that raw quadrupled the upload and is
        // the mechanism behind the transcription timeouts.
        //
        // The file is created FIRST and the converter is built to match its
        // `processingFormat`, not the other way round. That ordering is the
        // whole fix: `AVAudioFile.processingFormat` is always Float32,
        // whatever the file's on-disk settings say, so a converter built to
        // emit Int16 produces buffers the file rejects — every write failed
        // with -50 and `'fmt?'`, and the recording came out empty while
        // every other number looked healthy.
        let fileSettings = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000, channels: 1,
                                         interleaved: true)?.settings

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: fileSettings ?? format.settings)
        } catch {
            SaylineLog.log("failed to create audio file: \(error)")
            return false
        }

        // Ask the file what it wants, then build a converter that produces
        // exactly that.
        if let processing = audioFile?.processingFormat, processing != format {
            converter = AVAudioConverter(from: format, to: processing)
            // Tell it WHICH channel to take.
            //
            // Voice processing presents a 9-channel input here, and
            // `AVAudioConverter`'s default map for 9->1 is `[-1]`, which
            // means "fill the output with silence". It did exactly that:
            // recordings of the right length, the right sample rate and the
            // right file size, containing nothing at all. Every channel was
            // measured carrying the same signal (peak 0.3857), so channel 0
            // is as good as any.
            if let converter, processing.channelCount == 1, format.channelCount > 1 {
                converter.channelMap = [0]
                SaylineLog.log("[mic] downmixing \(format.channelCount)ch -> mono from channel 0")
            }
            if converter == nil {
                SaylineLog.log("[mic] no converter \(Int(format.sampleRate))Hz \(format.channelCount)ch"
                    + " -> \(Int(processing.sampleRate))Hz \(processing.channelCount)ch — recording raw instead")
                // Rewrite the file in the hardware format so writes match.
                audioFile = try? AVAudioFile(forWriting: url, settings: format.settings)
            }
        } else {
            converter = nil
        }

        framesWritten = 0
        // Temporary diagnostics for the zero-frame bug of 2026-08-12, where
        // every recording produced frames: 0 while an independent
        // AVAudioEngine in another process captured 48000 in three seconds
        // on the same device. The question these answer is the one the log
        // could not: does the tap fire at all, and if so with what?
        tapCallbacks = 0
        firstBufferLogged = false
        // The number the whole plan turns on: how long after the key went
        // down did real audio arrive. The per-hold voice-processing toggle
        // pushed this past a second, and nothing measured it.
        startRequestedAt = Date()
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
                let waited = self.startRequestedAt.map { Date().timeIntervalSince($0) * 1000 } ?? -1
                SaylineLog.log(String(format: "[mic] first audio after %.0f ms — %u frames, peak %.3f",
                                      waited, buffer.frameLength, peak))
            }
            guard let file = self.audioFile else { return }
            do {
                let toWrite = self.converted(buffer, to: file.processingFormat) ?? buffer
                try file.write(from: toWrite)
                self.framesWritten += AVAudioFramePosition(toWrite.frameLength)
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
            audioFileFormatDescription = audioFile.map {
                "\(Int($0.processingFormat.sampleRate))Hz \($0.processingFormat.channelCount)ch"
            }
            SaylineLog.log("recording started on \(lastInputDeviceName) at \(Int(format.sampleRate)) Hz -> \(url.path)")
            return true
        } catch {
            SaylineLog.log("failed to start audio engine"
                + (withVoiceProcessing ? " (voice processing on)" : " (voice processing off)")
                + ": \(error)")
            input.removeTap(onBus: 0)
            audioFile = nil
            // The file was created before the engine was asked to run, so a
            // failed attempt leaves an empty .wav behind. Without this the
            // retry's `discardLastRecording` is the only thing that removes
            // it, and on the final failure nothing does.
            try? FileManager.default.removeItem(at: url)
            lastRecordingURL = nil
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

    /// What actually landed on disk, for the upload-size question.
    private var audioFileFormatDescription: String?
    /// When this hold asked for the engine, so first-audio latency is a
    /// measured number rather than an impression.
    private var startRequestedAt: Date?

    private func stopOnAudioQueue() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        lastRecordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        SaylineLog.log("recording stopped -> \(lastRecordingURL?.path ?? "?") duration: \(lastRecordingDuration)s frames: \(framesWritten)")
        let bytes = lastRecordingURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        let written = audioFileFormatDescription ?? "?"
        SaylineLog.log("[mic] tap fired \(tapCallbacks) time(s); wrote \(written); "
            + "file \(bytes / 1024) KB")
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

    /// Pins the input to a chosen device, when that is worth doing at all.
    ///
    /// Skipped when the chosen device is already the system default — which
    /// is the common case, since the default pick is the built-in
    /// microphone. Forcing it gains nothing and is the call that can fail
    /// and leave the unit deviceless, so the safest version of this work is
    /// the version that does not happen.
    private func applyPreferredDevice(_ uid: String?, on input: AVAudioInputNode) {
        guard let deviceID = resolvedPin(uid) else { return }
        setInputDevice(deviceID, on: input)
        appliedDeviceID = deviceID
    }

    /// The device we should pin to, or nil for "follow the system".
    ///
    /// A pin equal to the current default is normalised away entirely. That
    /// is the common case — the stored pin was `BuiltInMicrophoneDevice`,
    /// which *is* the default — and it is the call that failed with -10851
    /// and left the unit with no device at all. Work that need not happen
    /// cannot fail.
    private func resolvedPin(_ uid: String?) -> AudioDeviceID? {
        guard let uid, let deviceID = AudioDeviceLister.deviceID(forUID: uid) else { return nil }
        return deviceID == Self.defaultInputDeviceID() ? nil : deviceID
    }

    /// True only when the pin differs from what is already applied.
    private func deviceNeedsApplying(_ uid: String?) -> Bool {
        guard let deviceID = resolvedPin(uid) else { return false }
        return deviceID != appliedDeviceID
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    /// Downsamples one tap buffer. Returns nil to write the original,
    /// which is the fail-open path — an oversized recording still
    /// transcribes, a dropped one does not.
    private func converted(_ buffer: AVAudioPCMBuffer,
                           to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Identity, not just sample rate: a converter emitting Int16 into a
        // Float32 file is exactly the mismatch that silently produced empty
        // recordings, and comparing sample rates alone did not catch it.
        guard let converter, converter.outputFormat == format else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError {
            SaylineLog.log("[mic] conversion failed: \(conversionError.localizedDescription)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
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
            // Do not leave a half-set unit behind. The failure itself is
            // survivable — the system default input is a perfectly good
            // fallback — but a unit left pointing at nothing records
            // silence while claiming to work.
            SaylineLog.log("couldn't pin the input device (status \(status)) — following the system default instead")
            var fallback = Self.defaultInputDeviceID()
            if fallback != 0 {
                AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &fallback,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
            }
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
