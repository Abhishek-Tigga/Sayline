import AVFoundation
import CoreAudio

/// Records microphone audio to a temp .wav file for the duration of a tap-hold.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?
    private var recordingStartTime: Date?
    private(set) var lastRecordingDuration: TimeInterval = 0
    /// Frames the tap actually wrote. Zero means the device accepted the
    /// engine but never delivered audio — see `capturedNoAudio`.
    private var framesWritten: AVAudioFramePosition = 0
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
    func start(preferredDeviceUID: String? = nil) {
        guard !isRecording else { return }

        // Safety net for the lifecycle above: even if a consumer forgot to
        // discard, the previous recording dies here.
        discardLastRecording()

        let input = engine.inputNode

        if let preferredDeviceUID, let deviceID = AudioDeviceLister.deviceID(forUID: preferredDeviceUID) {
            setInputDevice(deviceID, on: input)
        }

        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayline-\(UUID().uuidString).wav")

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            SaylineLog.log("failed to create audio file: \(error)")
            return
        }

        framesWritten = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
                self.framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                SaylineLog.log("failed writing audio buffer: \(error)")
            }
        }

        do {
            try engine.start()
            isRecording = true
            lastRecordingURL = url
            recordingStartTime = Date()
            // Read after start, not before. Before the engine runs, the audio
            // unit still reports whatever device it was initialised with, so
            // the log claimed "MacBook Air Microphone" while the engine was
            // actually on a Bluetooth device. Logging the format too, because
            // 16 kHz on a device that should do 48 kHz is the tell.
            lastInputDeviceName = currentInputDeviceName()
            SaylineLog.log("recording started on \(lastInputDeviceName) at \(Int(format.sampleRate)) Hz -> \(url.path)")
        } catch {
            SaylineLog.log("failed to start audio engine: \(error)")
            input.removeTap(onBus: 0)
            audioFile = nil
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false
        lastRecordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        SaylineLog.log("recording stopped -> \(lastRecordingURL?.path ?? "?") duration: \(lastRecordingDuration)s frames: \(framesWritten)")
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
