import AVFoundation

/// Two short hotkey-down/hotkey-up tones, synthesized in code rather than
/// bundled as audio assets — there's no safe source to pull a real sound
/// file from mid-session, and a generated tone gives full control over
/// the "somewhat bass-heavy" character that was asked for anyway
/// (loosely inspired by Wispr Flow's start/stop ding, not a copy of it).
final class SoundEffectPlayer {
    static let shared = SoundEffectPlayer()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let startBuffer: AVAudioPCMBuffer
    private let stopBuffer: AVAudioPCMBuffer

    private init() {
        let sampleRate = 44_100.0
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        // Rising two-tone on the way in, falling on the way out — both
        // anchored low (180/140Hz) rather than a bright, thin "beep".
        startBuffer = Self.makeChime(frequencies: [180, 340], sampleRate: sampleRate, duration: 0.16, format: format)
        stopBuffer = Self.makeChime(frequencies: [260, 140], sampleRate: sampleRate, duration: 0.14, format: format)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        // Deliberately NOT started here.
        //
        // This engine used to run from launch to quit, holding an output
        // stream open for the whole session so the process never went
        // audio-quiet. macOS restores other apps' volume when the ducking
        // process falls silent, and this one never did — so a duck that
        // should have lifted in a second lasted as long as the app.
        //
        // Nothing is held while idle: started for a chime, stopped after.
    }

    func playHotkeyDown() { play(startBuffer) }
    func playHotkeyUp() { play(stopBuffer) }

    private func play(_ buffer: AVAudioPCMBuffer) {
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            SaylineLog.log("sound engine failed to start -> \(error.localizedDescription)")
            return
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            // Off the render thread, and after a beat so a second chime
            // arriving immediately (hold-down then hold-up) does not have
            // the engine pulled out from under it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let self, !self.playerNode.isPlaying else { return }
                self.engine.stop()
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// A short percussive blip: each frequency is a plain sine under its
    /// own fast exponential decay, with the second tone entering partway
    /// through the first's decay so it reads as one quick "ding" rather
    /// than two overlapping notes.
    private static func makeChime(frequencies: [Double], sampleRate: Double, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]

        let decay = 10.0
        let noteGap = duration * 0.35

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            var sample = sin(2 * .pi * frequencies[0] * t) * exp(-decay * t)
            if frequencies.count > 1, t > noteGap {
                let t2 = t - noteGap
                sample += sin(2 * .pi * frequencies[1] * t2) * exp(-decay * t2) * 0.8
            }
            channel[i] = Float(sample * 0.35)
        }
        return buffer
    }
}
