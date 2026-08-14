// Rebuild after ANY FactGuard/SpokenNumbers change, or it scores with old rules:
//   swiftc -o eval/work-mode/verifier/verify Sources/Sayline/FactGuard.swift \
//     Sources/Sayline/SpokenNumbers.swift Sources/Sayline/AppContext.swift \
//     eval/work-mode/verifier/main.swift
import Foundation

// Two modes:
//   verify            stdin {"raw","rewrite"} per line -> violations
//   verify --pin      stdin {"raw"}            per line -> pinned block
//
// The --pin mode exists so the harness builds its prompt from the SAME
// extraction that scores the result. Decision 2's whole property is that
// the prompt and the guard cannot drift; a harness that wrote its own
// pinned block would break that before the feature even shipped.
if CommandLine.arguments.contains("--pin") {
    while let line = readLine(strippingNewline: true), !line.isEmpty {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["raw"] as? String else { exit(2) }
        print(FactGuard.promptBlock(for: FactGuard.extract(from: raw))
            .replacingOccurrences(of: "\n", with: " | "))
    }
    exit(0)
}

// stdin: one {"raw": "...", "rewrite": "...", "context": "email"} per line
// stdout: one {"violations": [{"kind": "...", "detail": "..."}]} per line
//
// The harness scores with THIS, not with a Python copy of the rules. A
// reimplementation would drift, and a scorer that disagrees with
// production measures the wrong thing.
//
// `context` is optional and defaults to `.general`. It was missing
// entirely until 2026-08-14, which meant NO email case had ever received
// the +12 shell allowance in any scoring run — every greeting and
// sign-off was measured against a ceiling that did not know they were
// allowed. `taste_score.py` had worked around it by keeping its own
// ceiling in Python, so the two disagreed by twelve words on exactly the
// cases the allowance exists for. The workaround is now deleted; this is
// the one ceiling.
while let line = readLine(strippingNewline: true), !line.isEmpty {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = obj["raw"] as? String, let rewrite = obj["rewrite"] as? String else {
        FileHandle.standardError.write(Data("bad input line\n".utf8)); exit(2)
    }
    let context = (obj["context"] as? String).flatMap(AppContext.init(rawValue:)) ?? .general
    let violations = FactGuard.verify(raw: raw, rewrite: rewrite, context: context)
    let payload: [String: Any] = ["violations": violations.map {
        ["kind": $0.kind, "detail": $0.explanation]
    }]
    let out = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(data: out, encoding: .utf8)!)
}
