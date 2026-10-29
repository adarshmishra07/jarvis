import Foundation

/// Speech is expected in English, Hindi or a mix. Output in any other script means the model guessed the wrong language.
public enum SpeechScript {
    /// Whether to keep what the speech model heard: it must have taken the speech for English or Hindi. Marathi or
    /// Nepali share Hindi's script, so the script alone cannot tell; then the language it reports does.
    public static func accepts(language: String?, text: String) -> Bool {
        guard isEnglishOrHindi(text) else { return false }
        guard let language, !language.isEmpty else { return true }
        return language.lowercased().split(separator: ",").allSatisfy { ["english", "hindi"].contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func isEnglishOrHindi(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { s in
            s.value < 0x0250                                  // Latin, digits, ASCII punctuation
                || (0x0900...0x097F).contains(s.value)        // Devanagari
                || (0x2000...0x206F).contains(s.value)        // general punctuation
                || s.properties.isWhitespace
        }
    }

    /// A hint for the speech model so names like Acme are spelled right.
    public static func context(vocabulary: [String]) -> String {
        vocabulary.isEmpty ? "" : "Names and terms that may come up: \(vocabulary.joined(separator: ", "))."
    }

    /// True when a transcript is the expected-words list read back (the speech model does this on noise), not speech:
    /// the list's own heading, or four or more comma-separated items that are mostly words from the list.
    public static func isContextEcho(_ text: String, vocabulary: [String]) -> Bool {
        if text.lowercased().contains("names and terms that may come up") { return true }
        let known = Set(vocabulary.map { $0.lowercased() })
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() }
        let listed = items.filter { known.contains($0) || known.contains($0 + ")") }.count
        return items.count >= 4 && Double(listed) >= Double(items.count) * 0.6
    }

    /// Applies learned spelling fixes ("zentra" to "Zentro") to whole words, in any case.
    public static func fixSpelling(_ text: String, _ map: [String: String]) -> String {
        map.reduce(text) { out, pair in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: pair.key) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return out }
            return re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: pair.value))
        }
    }
}
