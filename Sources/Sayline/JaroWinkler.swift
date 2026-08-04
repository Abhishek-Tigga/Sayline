import Foundation

/// Standard Jaro-Winkler string similarity — used by VoiceCommand to
/// tolerate minor transcription noise (a misheard word, a stray
/// character) without needing exact string equality. Self-contained, no
/// dependency, deterministic — no LLM or network call involved. Chosen
/// over Levenshtein specifically because it's the established technique
/// for short-string matching, with built-in prefix weighting.
enum JaroWinkler {
    static func similarity(_ a: String, _ b: String, prefixScale: Double = 0.1) -> Double {
        let jaro = jaroSimilarity(a, b)
        guard jaro > 0 else { return 0 }

        let aChars = Array(a)
        let bChars = Array(b)
        var prefixLength = 0
        for i in 0..<min(4, min(aChars.count, bChars.count)) {
            if aChars[i] == bChars[i] {
                prefixLength += 1
            } else {
                break
            }
        }
        return jaro + Double(prefixLength) * prefixScale * (1 - jaro)
    }

    private static func jaroSimilarity(_ a: String, _ b: String) -> Double {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty && bChars.isEmpty { return 1 }
        if aChars.isEmpty || bChars.isEmpty { return 0 }

        let matchDistance = max(0, max(aChars.count, bChars.count) / 2 - 1)

        var aMatches = [Bool](repeating: false, count: aChars.count)
        var bMatches = [Bool](repeating: false, count: bChars.count)
        var matches = 0

        for i in 0..<aChars.count {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, bChars.count)
            guard start < end else { continue }
            for j in start..<end {
                if bMatches[j] || aChars[i] != bChars[j] { continue }
                aMatches[i] = true
                bMatches[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var k = 0
        for i in 0..<aChars.count where aMatches[i] {
            while !bMatches[k] { k += 1 }
            if aChars[i] != bChars[k] { transpositions += 1 }
            k += 1
        }
        transpositions /= 2

        let m = Double(matches)
        return (m / Double(aChars.count) + m / Double(bChars.count) + (m - Double(transpositions)) / m) / 3
    }
}
