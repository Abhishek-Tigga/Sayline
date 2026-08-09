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

        let input = engine.inputNode

        if let preferredDeviceUID, let deviceID = AudioDeviceLister.deviceID(forUID: preferredDeviceUID) {
            setInputDevice(deviceID, on: input)
        }

        let format = input.outputFormat(forBus: 0)
        NSLog("Sayline: input device -> \(currentInputDeviceName())")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayline-\(UUID().uuidString).wav")

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            NSLog("Sayline: failed to create audio file: \(error)")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("Sayline: failed writing audio buffer: \(error)")
            }
        }

        do {
            try engine.start()
            isRecording = true
            lastRecordingURL = url
            recordingStartTime = Date()
            NSLog("Sayline: recording started -> \(url.path)")
        } catch {
            NSLog("Sayline: failed to start audio engine: \(error)")
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
        NSLog("Sayline: recording stopped -> \(lastRecordingURL?.path ?? "?") duration: \(lastRecordingDuration)s")
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
            NSLog("Sayline: recording \(lastRecordingDuration)s — too short to be speech, skipping")
            return true
        }

        guard let url = lastRecordingURL,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            NSLog("Sayline: couldn't measure audio level — transcribing anyway")
            return false // fail open
        }

        let samples = channelData[0]
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[i]))
        }

        // Deliberately generous. Room tone and mic self-noise peak around
        // 0.001–0.005; even quiet speech peaks well above 0.05. Logged so
        // the threshold can be tuned against real numbers instead of guesses.
        let isSilent = peak < 0.01
        NSLog("Sayline: audio peak \(peak) over \(lastRecordingDuration)s -> \(isSilent ? "silent, skipping" : "has speech")")
        return isSilent
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) {
        guard let audioUnit = node.audioUnit else {
            NSLog("Sayline: no audio unit available to set preferred input device")
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
            NSLog("Sayline: failed to set preferred input device -> status \(status)")
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
