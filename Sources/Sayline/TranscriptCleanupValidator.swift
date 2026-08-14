import Foundation

/// Treats the cleanup LLM's output as *proposed edits* against the raw
/// transcript, not as trusted text. Word-level diffs the two, then
/// classifies every edit against a whitelist (filler removal, repeat/
/// false-start removal, small grammar insertions, punctuation/
/// capitalization changes, near-word substitutions).
///
/// Two-tier design (2026-08-08 rewrite): a compliance *gate* runs first —
/// if too much of the raw transcript was touched by disallowed edits, the
/// LLM output is almost certainly an answer or a rewrite, not a cleanup,
/// and merging it word-by-word with the raw text produces mangled
/// punctuation/capitalization at every seam (confirmed live: "Is It
/// better to commit now. or wait until tomorrow?"). In that case the LLM
/// output is discarded entirely and a deterministic `tidy(_:)` pass runs
/// on the raw transcript instead — no seams, because nothing gets
/// stitched. Below the gate, the LLM output is trusted enough to merge
/// normally, with a smoothing pass to fix the casing/punctuation seams
/// that do occur at restored words.
///
/// Known, accepted trade-off: legitimate large rewrites (reordering,
/// unrelated substitutions) also trip the gate and get reverted —
/// preservation of the user's actual words is the explicit priority,
/// not maximally polished output.
enum TranscriptCleanupValidator {

    private static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "erm", "hmm", "like"]
    private static let bigramFillers: Set<String> = ["you know", "i mean", "sort of", "kind of"]
    /// Only stripped at a true sentence start (position 0, or right after
    /// a raw word ending in . ? !) — mid-sentence "so" ("commit now so
    /// we're safe") is real content, not a discourse filler.
    private static let discourseStarters: Set<String> = ["so", "well", "okay", "anyway"]
    /// Small grammar-fix insertions the LLM is allowed to add without a
    /// matching raw word — capped per call so an answer can't sneak in
    /// two words at a time and stay under the gate.
    private static let insertableWords: Set<String> = ["a", "an", "the", "to", "is"]
    private static let maxInsertionsAllowed = 2
    private static let maxFalseStartRunLength = 3
    /// Fraction of raw tokens that may be touched by disallowed edits
    /// before the LLM output is discarded outright. Chosen from the
    /// simulated compliant/non-compliant cases (2026-08-08): real cleanup
    /// passes stay near 0%, real answers/rewrites land well above 50%.
    private static let complianceGateThreshold = 0.30

    private enum DiffOp {
        case equal(rawIndex: Int, cleanedIndex: Int)
        case delete(rawIndex: Int)
        case insert(cleanedIndex: Int)
    }

    private enum Decision {
        case equal(cleanedIndex: Int, rawIndex: Int)
        case substitution(cleanedIndex: Int, rawIndex: Int)
        case restore(rawIndex: Int)
        case dropRaw
        case insertCleaned(cleanedIndex: Int)
        case rejectInsert
    }

    private enum TokenSource {
        /// Sourced from the cleaned side, paired with the raw word it
        /// replaced — casing authority defaults to raw at non-sentence-
        /// boundary positions (see `smooth`).
        case cleanedPaired(rawIndex: Int)
        /// A free grammar-fix insertion with no raw counterpart.
        case cleanedFree
        case raw
    }

    static func validate(raw: String, cleaned: String) -> String {
        let rawTokens = raw.split(separator: " ").map(String.init)
        let cleanedTokens = cleaned.split(separator: " ").map(String.init)
        guard !rawTokens.isEmpty else { return cleaned }
        guard !cleanedTokens.isEmpty else { return tidy(raw) }

        let rawCores = rawTokens.map(core)
        let cleanedCores = cleanedTokens.map(core)
        let ops = diff(rawCores, cleanedCores)
        let falseStarts = falseStartIndices(ops: ops, rawCores: rawCores)

        // The one scoped waiver: a span the speaker themselves took back.
        //
        // Detection is `FactGuard`'s, not a second implementation — same
        // phrase markers, same same-class-successor rule, same boundary
        // cases already in a suite. This file only decides what may be
        // deleted; whether a droppable reason SHOULD go is the model's
        // call on two prompt lines.
        //
        // Consumed as a multiset so over-deletion is bounded to exactly
        // the words the span permits. Everything outside it is as
        // protected as it was before this feature existed.
        var retractionBudget: [String: Int] = [:]
        for word in FactGuard.retractionDroppableWords(raw: raw, cleaned: cleaned) {
            retractionBudget[budgetKey(word), default: 0] += 1
        }

        // Relocation, not deletion. Inside a retraction the model may
        // move the replacement to where the retracted value stood, and a
        // positional diff reads that as the successor being deleted from
        // its old slot. It is only safe to permit when the cleaned text
        // still carries at least as many copies of the word as the raw
        // did — then nothing is lost, which is the whole contract.
        //
        // C2 is why this is a count and not a flag: "forty thousand,
        // sorry, forty five thousand" needs its second "forty", and a
        // rule that merely knew the word survived somewhere deleted it
        // and produced 5,000.
        var relocatable: Set<String> = []
        if !retractionBudget.isEmpty {
            var rawCount: [String: Int] = [:], cleanedCount: [String: Int] = [:]
            for t in rawCores { rawCount[budgetKey(t), default: 0] += 1 }
            for t in cleanedCores { cleanedCount[budgetKey(t), default: 0] += 1 }
            for (k, n) in rawCount where (cleanedCount[k] ?? 0) >= n { relocatable.insert(k) }
        }

        let decisions = buildDecisions(
            ops: ops, rawTokens: rawTokens, rawCores: rawCores,
            cleanedTokens: cleanedTokens, cleanedCores: cleanedCores,
            falseStartIndices: falseStarts, retractionBudget: &retractionBudget,
            relocatable: relocatable
        )

        let disallowed = decisions.reduce(0) { count, d in
            switch d {
            case .restore, .rejectInsert: return count + 1
            default: return count
            }
        }
        let fraction = Double(disallowed) / Double(rawTokens.count)
        guard fraction <= complianceGateThreshold else {
            return tidy(raw) // LLM output looked like an answer/rewrite, not a cleanup — discard it entirely
        }

        var tokens: [String] = []
        var sources: [TokenSource] = []
        for d in decisions {
            switch d {
            case .equal(let ci, let ri), .substitution(let ci, let ri):
                tokens.append(cleanedTokens[ci])
                sources.append(.cleanedPaired(rawIndex: ri))
            case .restore(let ri):
                tokens.append(rawTokens[ri])
                sources.append(.raw)
            case .insertCleaned(let ci):
                tokens.append(cleanedTokens[ci])
                sources.append(.cleanedFree)
            case .dropRaw, .rejectInsert:
                break
            }
        }

        return finalize(smooth(tokens: tokens, sources: sources, rawTokens: rawTokens), raw: raw)
    }

    // MARK: - Decision pass

    private static func buildDecisions(
        ops: [DiffOp], rawTokens: [String], rawCores: [String],
        cleanedTokens: [String], cleanedCores: [String],
        falseStartIndices: Set<Int>, retractionBudget: inout [String: Int],
        relocatable: Set<String>
    ) -> [Decision] {
        var decisions: [Decision] = []
        var insertionsUsed = 0
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal(let ri, let ci):
                decisions.append(.equal(cleanedIndex: ci, rawIndex: ri))
                i += 1

            case .delete(let ri):
                if i + 1 < ops.count, case .insert(let ci) = ops[i + 1],
                   isNearWord(rawCores[ri], cleanedCores[ci]) {
                    decisions.append(.substitution(cleanedIndex: ci, rawIndex: ri))
                    i += 2
                    continue
                }
                if isAllowedDeletion(rawTokens: rawTokens, rawCores: rawCores, index: ri,
                                     falseStartIndices: falseStartIndices,
                                     retractionBudget: &retractionBudget,
                                     relocatable: relocatable) {
                    decisions.append(.dropRaw)
                } else {
                    decisions.append(.restore(rawIndex: ri))
                }
                i += 1

            case .insert(let ci):
                if i + 1 < ops.count, case .delete(let ri) = ops[i + 1],
                   isNearWord(rawCores[ri], cleanedCores[ci]) {
                    decisions.append(.substitution(cleanedIndex: ci, rawIndex: ri))
                    i += 2
                    continue
                }
                if insertableWords.contains(cleanedCores[ci]), insertionsUsed < maxInsertionsAllowed {
                    decisions.append(.insertCleaned(cleanedIndex: ci))
                    insertionsUsed += 1
                } else {
                    decisions.append(.rejectInsert)
                }
                i += 1
            }
        }
        return decisions
    }

    private static func isAllowedDeletion(rawTokens: [String], rawCores: [String], index: Int,
                                          falseStartIndices: Set<Int>,
                                          retractionBudget: inout [String: Int],
                                          relocatable: Set<String>) -> Bool {
        let c = rawCores[index]
        if fillerWords.contains(c) { return true }
        if !c.isEmpty, index > 0, rawCores[index - 1] == c { return true } // repeat of previous word
        if !c.isEmpty, index < rawCores.count - 1, rawCores[index + 1] == c { return true } // false start (exact adjacent repeat)
        if falseStartIndices.contains(index) { return true } // false start (restart run, see falseStartIndices)
        if discourseStarters.contains(c), index == 0 || endsSentence(rawTokens[index - 1]) { return true }
        if index + 1 < rawCores.count, bigramFillers.contains("\(c) \(rawCores[index + 1])") { return true }
        if index > 0, bigramFillers.contains("\(rawCores[index - 1]) \(c)") { return true }

        // Last, and only last: the scoped self-correction waiver. Every
        // rule above is unchanged, so a word outside a retraction is
        // exactly as protected as it was before this feature shipped.
        //
        // The budget is consumed, not merely consulted. "Ask Rohan… no
        // wait I mean Rohit, Rohan's on leave" makes ONE "Rohan"
        // droppable, and the second one — the reason the reader needs —
        // finds the budget empty and is restored.
        let key = budgetKey(c)
        if let remaining = retractionBudget[key], remaining > 0 {
            retractionBudget[key] = remaining - 1
            return true
        }
        // Moved, not lost — see `relocatable`.
        if !retractionBudget.isEmpty, relocatable.contains(key) { return true }
        return false
    }

    /// Raw indices belonging to a short deleted run (≤3 tokens) that ends
    /// by repeating the most recently kept raw word — e.g. "I went to |I
    /// drove| to the store": "went"/"to" aren't fillers or exact repeats
    /// individually, but the whole run is a restart the speaker abandoned
    /// mid-word.
    private static func falseStartIndices(ops: [DiffOp], rawCores: [String]) -> Set<Int> {
        var allowed = Set<Int>()
        var lastKept: Int?
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal(let ri, _):
                lastKept = ri
                i += 1
            case .delete:
                var run: [Int] = []
                var k = i
                while k < ops.count, case .delete(let ri) = ops[k] {
                    run.append(ri)
                    k += 1
                }
                if run.count <= maxFalseStartRunLength, let lk = lastKept, let last = run.last,
                   !rawCores[last].isEmpty, rawCores[last] == rawCores[lk] {
                    allowed.formUnion(run)
                }
                i = k
            case .insert:
                i += 1
            }
        }
        return allowed
    }

    // MARK: - Smoothing (compliant path only)

    /// Repairs the punctuation/casing seams that appear where a restored
    /// raw word sits next to an LLM word — the actual thing that looked
    /// broken before this rewrite ("Is It better to commit now. or
    /// wait...").
    private static func smooth(tokens: [String], sources: [TokenSource], rawTokens: [String]) -> [String] {
        var toks = tokens
        guard !toks.isEmpty else { return toks }

        // Seam repair: a sentence-ender left stranded before a lowercase
        // continuation ("commit now. or wait until tomorrow") is an
        // artifact of stitching cleaned and raw tokens together, so it
        // goes.
        //
        // **Only the full stop.** This set was ".,;" until 2026-08-14, and
        // that made it delete every comma and semicolon that preceded a
        // lowercase word — which is to say nearly every correct one in
        // English. "Hey Priya, quick question" lost its comma. "the
        // sandbox access, the API docs, and a support contact" lost both.
        // "No rush, just checking" lost the one comma that failed A3.
        //
        // Clean's baseline round read this as small-model behaviour and
        // made a model upgrade the headline workstream. It was not: fed
        // the user's own expected output verbatim, this loop stripped the
        // commas back out. Colons and question marks survived only by
        // being absent from the set. See `review/LEDGER.md`.
        //
        // A comma before a lowercase word is ordinary English. A full stop
        // before one is a seam. Only the second is ours to remove.
        for k in 0..<(toks.count - 1) {
            guard let nextFirst = toks[k + 1].first, nextFirst.isLowercase else { continue }
            while let last = toks[k].last, last == "." {
                toks[k].removeLast()
            }
        }

        for k in 1..<toks.count {
            guard case .cleanedPaired(let ri) = sources[k] else { continue }
            let prevEndsSentence = endsSentence(toks[k - 1])
            guard !prevEndsSentence else { continue }
            guard let rawFirst = rawTokens[ri].first, rawFirst.isLowercase else { continue }
            guard let curFirst = toks[k].first, curFirst.isUppercase, core(toks[k]) != "i" else { continue }
            toks[k] = String(rawFirst) + toks[k].dropFirst()
        }

        return toks
    }

    private static func finalize(_ tokens: [String], raw: String) -> String {
        guard !tokens.isEmpty else { return "" }
        var toks = tokens
        if let first = toks[0].first, first.isLowercase {
            toks[0] = first.uppercased() + toks[0].dropFirst()
        }
        var result = toks.joined(separator: " ")
        if !endsSentence(result) {
            result += raw.trimmingCharacters(in: .whitespaces).hasSuffix("?") ? "?" : "."
        }
        return result
    }

    /// Deterministic fallback used both when the compliance gate rejects
    /// the LLM output and when the LLM returns nothing usable: strips
    /// fillers ourselves, collapses exact adjacent repeats, and fixes
    /// sentence-boundary capitalization — no LLM output involved, so
    /// there are no seams to smooth.
    private static func tidy(_ raw: String) -> String {
        let rawTokens = raw.split(separator: " ").map(String.init)
        guard !rawTokens.isEmpty else { return raw }
        let rawCores = rawTokens.map(core)

        var out: [String] = []
        var i = 0
        while i < rawTokens.count {
            let c = rawCores[i]
            if fillerWords.contains(c) { i += 1; continue }
            if i + 1 < rawTokens.count, bigramFillers.contains("\(c) \(rawCores[i + 1])") { i += 2; continue }
            if let lastOut = out.last, !c.isEmpty, core(lastOut) == c { i += 1; continue }
            out.append(rawTokens[i])
            i += 1
        }

        for k in 1..<max(out.count, 1) where k < out.count {
            if endsSentence(out[k - 1]), let f = out[k].first, f.isLowercase {
                out[k] = f.uppercased() + out[k].dropFirst()
            }
        }

        return finalize(out, raw: raw)
    }

    private static func endsSentence(_ token: String) -> Bool {
        var chars = Array(token)
        if chars.last == "\"" { chars.removeLast() }
        guard let last = chars.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// Lowercased, punctuation-stripped form used for alignment so that
    /// e.g. "Store," and "store" line up as the same word.
    /// One spelling for budget lookups, because the two files normalize
    /// differently and neither is wrong for its own job.
    ///
    /// `core` keeps interior apostrophes ("let's"). `FactGuard`
    /// deliberately folds possessives — its `normalizeWords` maps "'s "
    /// to " " so that "Mira's" and "Mira" compare equal, which also turns
    /// "let's go" into "let go". So the same token arrives here as
    /// "let's" and as "let", and C1 restored a stray "let's" into the
    /// middle of an otherwise correct sentence.
    ///
    /// Folding to a common form — apostrophes out, one trailing "s" out —
    /// reconciles them. It conflates "team" with "teams", which is
    /// tolerable precisely because this key is only ever consulted inside
    /// a retraction span and is bounded by an exact count: the worst case
    /// is one extra droppable word in a region the speaker already took
    /// back, never anywhere else in the sentence.
    private static func budgetKey(_ token: String) -> String {
        var k = core(token)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        if k.count > 1, k.hasSuffix("s") { k.removeLast() }
        return k
    }

    private static func core(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Small edit distance relative to word length — catches contraction/
    /// inflection fixes (dont -> don't, go -> goes) without letting
    /// wholesale word swaps through as "near".
    private static func isNearWord(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let distance = editDistance(a, b)
        return distance <= 2 && Double(distance) <= Double(max(a.count, b.count)) / 2
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previousRow = Array(0...b.count)
        var currentRow = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            currentRow[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    currentRow[j] = previousRow[j - 1]
                } else {
                    currentRow[j] = 1 + min(previousRow[j - 1], previousRow[j], currentRow[j - 1])
                }
            }
            previousRow = currentRow
        }
        return previousRow[b.count]
    }

    /// Standard LCS-based word diff. Runs on the normalized cores so
    /// punctuation/capitalization differences don't block a match.
    private static func diff(_ a: [String], _ b: [String]) -> [DiffOp] {
        let n = a.count, m = b.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append(.equal(rawIndex: i, cleanedIndex: j))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.delete(rawIndex: i))
                i += 1
            } else {
                ops.append(.insert(cleanedIndex: j))
                j += 1
            }
        }
        while i < n { ops.append(.delete(rawIndex: i)); i += 1 }
        while j < m { ops.append(.insert(cleanedIndex: j)); j += 1 }
        return ops
    }
}
