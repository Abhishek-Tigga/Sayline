import Foundation

// stdin: one {"raw": "...", "cleaned": "..."} per line
// stdout: one {"validated": "..."} per line
//
// The harness validates with THIS, the compiled production validator, not
// a Python reimplementation. The work-mode harness learned that lesson
// three times; this one starts with it.
while let line = readLine(strippingNewline: true), !line.isEmpty {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = obj["raw"] as? String, let cleaned = obj["cleaned"] as? String else {
        FileHandle.standardError.write(Data("bad input line\n".utf8)); exit(2)
    }
    let payload = ["validated": TranscriptCleanupValidator.validate(raw: raw, cleaned: cleaned)]
    let out = try! JSONSerialization.data(withJSONObject: payload)
    print(String(data: out, encoding: .utf8)!)
}
