import Contacts
import Foundation

/// Gathers the real sources and hands them to `VocabularyBias`, keeping
/// the result where the transcriber can read it.
///
/// Rebuilt at launch and when an input changes — never mid-dictation:
/// the list a recording started with is the list it is scored with
/// (decision 5). Every source fails open (decision 9.4): Contacts not
/// granted means no names, a missing dictionary means no app filter,
/// and an empty list means no prompt field at all. A biasing failure
/// must never cost a dictation, so nothing here throws past this file.
enum VocabularyBiasBuilder {
    static let myWordsDefaultsKey = "com.abhishektigga.sayline.myWords"

    private static let lock = NSLock()
    private static var current: String?
    private static var entries: [String] = []

    /// What the transcriber sends, or nil. Read on the transcription
    /// task, written on the main thread — hence the lock.
    static var currentGlossary: String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// The assembled list itself, for the echo guard: a transcript that
    /// recites these in order is Whisper reading our hint back, not the
    /// user speaking.
    static var currentEntries: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// `/usr/share/dict/words`, ~235k lowercase entries, shipped with
    /// every Mac. Chosen over NSSpellChecker deliberately: it needs no
    /// AppKit, so `--dump-config` builds the same list headless that
    /// the app builds live, and the eval reads production truth.
    private static let knownWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words",
                                     encoding: .utf8) else {
            SaylineLog.log("[bias] system dictionary unreadable — app-name filter off, all names admitted")
            return []
        }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// Assembles from all live sources. `historyText` is the caller's
    /// concatenated recent dictations — it ranks contacts, nothing else.
    static func rebuild(historyText: String) {
        let myWords = (UserDefaults.standard.string(forKey: myWordsDefaultsKey) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let assembled = VocabularyBias.assemble(
            myWords: myWords,
            contactFirstNames: contactFirstNames(),
            appNames: InstalledAppCatalog.biasCandidateNames,
            historyText: historyText,
            isKnownWord: { knownWords.isEmpty ? false : knownWords.contains($0) })
        let glossary = VocabularyBias.glossaryLine(assembled)

        lock.lock()
        current = glossary
        entries = assembled
        lock.unlock()

        if let glossary {
            SaylineLog.log("[bias] glossary rebuilt — \(assembled.count) entries, ~\(VocabularyBias.estimateTokens(glossary)) tokens")
        } else {
            SaylineLog.log("[bias] no vocabulary sources yet — transcription runs unbiased")
        }
    }

    /// First names only, and only if the user has already granted
    /// Contacts to something else (the WhatsApp share flow asks; this
    /// never does — biasing is not worth a permission dialog).
    private static func contactFirstNames() -> [String] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return []
        }
        let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor])
        var names: [String] = []
        do {
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                let given = contact.givenName.trimmingCharacters(in: .whitespaces)
                if !given.isEmpty { names.append(given) }
            }
        } catch {
            SaylineLog.log("[bias] contacts enumeration failed (\(error.localizedDescription)) — continuing without names")
        }
        return names
    }
}
