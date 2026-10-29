import Foundation

/// Numbers written out the way they are said, before English text goes to the voice: the voice model mangles digits
/// ("22" lost its first digit). "23:16" is "eleven sixteen PM", "$19" is "nineteen dollars", "22nd" is "twenty second".
public enum SpokenNumbers {
    private static let speller: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// A whole number in words, without hyphens ("twenty two").
    static func words(_ digits: String) -> String {
        guard let n = Int(digits.replacingOccurrences(of: ",", with: "")), let w = speller.string(from: NSNumber(value: n)) else { return digits }
        return w.replacingOccurrences(of: "-", with: " ")
    }

    private static let currencies: [Character: (one: String, many: String)] = ["$": ("dollar", "dollars"), "₹": ("rupee", "rupees"), "€": ("euro", "euros"), "£": ("pound", "pounds")]

    public static func expand(_ text: String) -> String {
        var s = text
        // 23:16, 7:30, 11:00 AM. A 24-hour time past noon or at midnight gets its PM or AM.
        s = replace(s, #"\b(\d{1,2}):(\d{2})\b(\s?[AaPp]\.?[Mm]\.?)?"#) { g in
            guard var h = Int(g[1]), let m = Int(g[2]), h < 24, m < 60 else { return g[0] }
            var suffix = g[3]
            if suffix.isEmpty, h >= 13 { h -= 12; suffix = " PM" } else if suffix.isEmpty, h == 0 { h = 12; suffix = " AM" }
            let minutes = m == 0 ? "o'clock" : m < 10 ? "oh \(words(String(m)))" : words(String(m))
            return "\(words(String(h))) \(minutes)\(suffix)"
        }
        s = replace(s, #"([$₹€£])\s?(\d[\d,]*)(?:\.(\d+))?"#) { g in
            guard let unit = currencies[Character(g[1])] else { return g[0] }
            let amount = g[3].isEmpty ? words(g[2]) : "\(words(g[2])) point \(digitWords(g[3]))"
            return "\(amount) \(g[2] == "1" && g[3].isEmpty ? unit.one : unit.many)"
        }
        s = replace(s, #"(\d[\d,]*)(?:\.(\d+))?\s?%"#) { g in (g[2].isEmpty ? words(g[1]) : "\(words(g[1])) point \(digitWords(g[2]))") + " percent" }
        s = replace(s, #"\b(\d+)(st|nd|rd|th)\b"#) { g in ordinal(words(g[1])) }
        s = replace(s, #"\b(\d+)\.(\d+)\b"#) { g in "\(words(g[1])) point \(digitWords(g[2]))" }
        // Digits stuck to a word ("GPT-4", "Web3") get a space; the rest are whole numbers, with or without commas.
        s = replace(s, #"(?<=[A-Za-z])-?(\d+)"#) { g in " " + words(g[1]) }
        s = replace(s, #"\d{1,3}(?:,\d{3})+|\d+"#) { g in words(g[0]) }
        return s
    }

    /// "zero point two five": digits after the point are read one by one.
    private static func digitWords(_ digits: String) -> String { digits.map { words(String($0)) }.joined(separator: " ") }

    private static func ordinal(_ cardinal: String) -> String {
        var parts = cardinal.split(separator: " ").map(String.init)
        guard let last = parts.popLast() else { return cardinal }
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        let word = irregular[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        return (parts + [word]).joined(separator: " ")
    }

    /// Replaces each match with `make(groups)`, where groups[0] is the whole match and a missing group is "".
    private static func replace(_ text: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out) else { continue }
            let groups = (0..<match.numberOfRanges).map { i in Range(match.range(at: i), in: out).map { String(out[$0]) } ?? "" }
            out.replaceSubrange(whole, with: make(groups))
        }
        return out
    }
}
