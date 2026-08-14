import AVFoundation
import Foundation

// Records one clip per scripted line, so ground truth is known and word
// error rate is mechanical. Standalone on purpose: rebuilding Sayline
// would reset the user's Accessibility and Microphone grants, which costs
// them more than this harness is worth.
struct Line: Decodable { let id: String; let text: String }

let root = FileManager.default.currentDirectoryPath + "/eval/transcription"
guard FileManager.default.fileExists(atPath: root + "/script.json") else {
    print("Run this from the repo root — no eval/transcription/script.json under "
          + FileManager.default.currentDirectoryPath)
    exit(1)
}
let allLines = try! JSONDecoder().decode(
    [Line].self, from: Data(contentsOf: URL(fileURLWithPath: root + "/script.json")))

// Optional id filters, so three new lines don't cost re-reading ten old
// ones: `record control` matches every id starting with "control";
// `record names-1 units` matches exactly those.
let filters = Array(CommandLine.arguments.dropFirst())
let lines = filters.isEmpty ? allLines : allLines.filter { line in
    filters.contains { line.id == $0 || line.id.hasPrefix($0) }
}
guard !lines.isEmpty else {
    print("No script lines match \(filters) — ids are: "
          + allLines.map(\.id).joined(separator: ", "))
    exit(1)
}

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
print("recording at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch\n")

for (index, line) in lines.enumerated() {
    print("\(index + 1)/\(lines.count)  \u{1B}[1m\(line.text)\u{1B}[0m")
    print("     press return, read it aloud, then press return again")
    _ = readLine()

    let url = URL(fileURLWithPath: "\(root)/clips/\(line.id).wav")
    try? FileManager.default.removeItem(at: url)
    guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
        print("     could not open the file"); continue
    }
    var frames: AVAudioFrameCount = 0
    var peak: Float = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        try? file.write(from: buffer)
        frames += buffer.frameLength
        if let d = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(d[i])) }
        }
    }
    try? engine.start()
    _ = readLine()
    engine.stop(); input.removeTap(onBus: 0)

    let seconds = Double(frames) / format.sampleRate
    // Assert on the payload, not the artifact: a file exists is not the
    // same as a file containing speech.
    let ok = seconds > 0.4 && peak > 0.02
    print(String(format: "     %@ %.1fs, peak %.2f\n",
                 ok ? "saved" : "TOO QUIET — rerecord this one", seconds, peak))
}
print("clips in \(root)/clips")
