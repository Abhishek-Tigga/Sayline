import Foundation

/// Spoken-number parsing, split out of `FactGuard` in the 2026-08-14
/// simplicity pass — a pure move, no logic changed. This is the layer
/// that makes "fifteen", "15", "forty five thousand", "45,000", "half"
/// and "1st" compare as the same fact. `FactGuard` extraction and
/// verification both call it; the suites that pin its behavior live in
/// `eval/factguard-checks` (they compile both files — see CLAUDE.md).
enum SpokenNumbers {
    // MARK: - Numbers, including the ones people say out loud

    static let spokenUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    static let spokenTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Words that multiply the number before them.
    ///
    /// "Forty five thousand" is 45,000, not 45. Without this the tens+units
    /// path stopped at 45, so a rewrite writing the figure the way anyone
    /// writes it — "45,000" — was scored as *both* losing 45 and inventing
    /// 45,000. Two violations for being correct.
    ///
    /// Found by pointing the stated rules at the fifteen rewrites the user
    /// accepted: it fires on N3, and on every rupee amount in real
    /// dictation. `lakh` and `crore` are here because this app's user
    /// dictates them, not for completeness.
    ///
    /// "k" earns its place the same way — "forty five k" is how the figure
    /// is spoken, and `splitDigitsFromLetters` already turns "45k" into
    /// "45" "k". It only ever multiplies a number that immediately
    /// precedes it, so a stray "K" cannot manufacture one.
    static let scaleWords: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "k": 1_000,
        "lakh": 100_000, "lakhs": 100_000,
        "million": 1_000_000, "crore": 10_000_000, "crores": 10_000_000,
        "billion": 1_000_000_000,
    ]

    /// Words that carry a quantity without being numbers.
    ///
    /// Without these the subset rule storms: a faithful rewrite of "both
    /// options" as "2 options" would report an invented 2. Mapped on both
    /// sides, so the two spellings of one quantity compare equal — the
    /// same reason "fifteen" and 15 do.
    ///
    /// "half" was here mapping to 1 and is deliberately gone. It is not a
    /// count, and "I don't want to half commit and then flake" pinned the
    /// number 1 on a phrase containing no quantity at all — so the
    /// accepted rewrite of E2, which drops the phrase, was charged with
    /// losing a number nobody said. Same failure as the bare "one", which
    /// this table's neighbour already guards against.
    static let quantityWords: [String: Int] = [
        "both": 2, "pair": 2, "couple": 2, "dozen": 12, "twice": 2,
        "single": 1, "once": 1, "thrice": 3,
    ]

    /// Ordinals small enough to be list markers in ordinary speech.
    static let enumerationMarkers: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth",
        "seventh", "eighth", "ninth", "tenth",
    ]

    static let spokenOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]

    /// "30th" -> 30. Nil when the word is not a digit-plus-suffix ordinal.
    static func ordinalValue(_ word: String) -> Int? {
        guard word.count > 2 else { return nil }
        let suffix = String(word.suffix(2))
        guard ["st", "nd", "rd", "th"].contains(suffix) else { return nil }
        return Int(word.dropLast(2))
    }

    /// Every number in the text, as digits.
    ///
    /// "Fifteen" and "15" are the same fact and must compare equal — the
    /// model is free to write either, and pinning the *value* rather than
    /// the spelling is what lets it.
    static func numbers(in words: [String]) -> Set<Int> {
        var found: Set<Int> = []
        var index = 0
        while index < words.count {
            guard let (value, next) = numberPhrase(in: words, at: index) else {
                index += 1
                continue
            }
            found.insert(value)
            index = next
        }
        return found
    }

    /// One number and the index just past it, or nil where a token looks
    /// numeric but is not a fact.
    ///
    /// Split out of `numbers(in:)` so that scale words ("thousand",
    /// "lakh") can multiply whatever form the number arrived in, without
    /// repeating the absorption in each of the six branches below.
    static func numberPhrase(in words: [String], at start: Int) -> (Int, Int)? {
        let word = words[start]
        var value: Int
        var index = start

        if let digits = Int(word) {
            value = digits
            index += 1
        }
        // "30th", "1st", "22nd" — a deadline is a number even when it
        // wears a suffix, and "cleared before the 30th" was previously
        // invisible to the guard entirely. Returns early: no one says
        // "the 30th thousand".
        else if let ordinal = ordinalValue(word) {
            return (ordinal, start + 1)
        }
        // "one" is usually prose, not a quantity. "quick one", "the
        // last one", "no one", "one more thing" — all pinned the
        // number 1 and then reported it lost when a faithful rewrite
        // dropped the phrase. It counts only when a unit follows, or
        // when a scale word makes it a figure in its own right ("one
        // lakh").
        else if word == "one" {
            let next = start + 1 < words.count ? words[start + 1] : ""
            guard FactGuard.unitWords.contains(next) || scaleWords[next] != nil else { return nil }
            value = 1
            index += 1
        }
        else if let quantity = quantityWords[word] {
            value = quantity
            index += 1
        }
        // A bare small ordinal is an enumeration marker, not a fact.
        //
        // "three reasons: first the cost, second the timeline" pinned
        // 1 and 2, so turning that into the bullet list the user asked
        // for dropped them and the guard fell back — on exactly the
        // output that was wanted. The prompt was fighting the guard.
        //
        // Digit ordinals ("the 30th") and compounds ("twenty first")
        // stay facts, because that is how a real date is spoken. The
        // cost is "the first of March" losing its 1; March is still
        // pinned, so the date is not wholly unprotected.
        else if enumerationMarkers.contains(word) {
            return nil
        }
        else if let unit = spokenUnits[word] ?? spokenOrdinals[word] {
            value = unit
            index += 1
        }
        else if let tens = spokenTens[word] {
            // "twenty five" is one number, not two.
            // "twenty five" and "twenty first" are both one number.
            value = tens
            index += 1
            if index < words.count,
               let unit = spokenUnits[words[index]] ?? spokenOrdinals[words[index]],
               unit < 10 {
                value += unit
                index += 1
            }
        }
        else {
            return nil
        }

        // Scale words multiply what came before, and chain: "two hundred
        // thousand" is 200,000. See `scaleWords` for why this was missing
        // and what it cost.
        while index < words.count, let scale = scaleWords[words[index]] {
            value *= scale
            index += 1
        }
        return (value, index)
    }
}
