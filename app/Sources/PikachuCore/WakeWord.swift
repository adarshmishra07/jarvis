import Foundation

/// What was said after "Hey Jarvis". Speech is transcribed on the Mac; only this decides whether Jarvis wakes.
public enum WakeCommand: Equatable {
    case listen
    case ask(String)
    case startNotes
    case stopNotes
    case sleep
}

public enum WakeWord {
    /// "Hey Jarvis", "Hi Jarvis" or "Hello Jarvis", and the ways speech-to-text tends to write them, in Latin or Hindi
    /// script, after at most a filler like "uh". The greeting is required and must come first, so talk about Jarvis
    /// never wakes it.
    private static let wake = try! NSRegularExpression(pattern: #"""
        ^\s*(?:(?:uh|um|so|oh|hmm)[\s,.!]+)?
        (?:(?:hey|hay|hei|hi|hii|hello|helo|hallo)[\s,.!-]*(?:jarvis|jarviss|jarvice|jarvish|jarvas|jarwis|jervis|javis)
          |(?:हे|हाय|हेलो|हैलो)[\s,.!]+(?:जार्विस|जारविस|जर्विस))
        (?=[\s,.!?।]|$)[\s,.!?।]*
        """#, options: [.caseInsensitive, .allowCommentsAndWhitespace])
    private static let startNotes = try! NSRegularExpression(pattern: #"^(please\s+)?((start|begin)\s+(taking\s+)?notes?|take\s+notes|start\s+note\s+taking)\b"#, options: [.caseInsensitive])
    private static let stopNotes = try! NSRegularExpression(pattern: #"^(please\s+)?((stop|end|finish)\s+(taking\s+)?notes?|(stop|end)\s+note\s+taking)\b"#, options: [.caseInsensitive])
    private static let sleep = try! NSRegularExpression(pattern: #"^(stop|goodbye|bye|go to sleep|that'?s all|that is all)\b[\s.!]*$"#, options: [.caseInsensitive])

    /// `learned`: how speech-to-text writes your own "Hey Jarvis" (from training), matched as whole words at the start.
    public static func parse(_ heard: String, learned: [String] = []) -> WakeCommand? {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        if let match = wake.firstMatch(in: text, range: range), let end = Range(match.range, in: text) {
            return command(String(text[end.upperBound...]))
        }
        let said = normalize(text)
        guard let phrase = learned.first(where: { said == $0 || said.hasPrefix($0 + " ") }) else { return nil }
        return command(String(said.dropFirst(phrase.count)))
    }

    /// Lowercase words only (Latin or Hindi script), single spaces: how a learned phrase is stored and compared.
    public static func normalize(_ text: String) -> String {
        let kept = String(String.UnicodeScalarView(text.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || CharacterSet.decimalDigits.contains($0) ? $0 : " "
        }))
        return kept.split(separator: " ").joined(separator: " ")
    }

    /// Phrases too common to wake on, however your voice writes "Hey Jarvis".
    private static let generic: Set<String> = ["hey", "hi", "hello", "okay", "ok", "hey there", "hi there", "hello there", "thank you", "hey you", "oh hey"]

    /// A training sample worth learning: two to four words, and not a phrase people say anyway.
    public static func learnable(_ heard: String) -> String? {
        let phrase = normalize(heard)
        let words = phrase.split(separator: " ").count
        return (2...4).contains(words) && !generic.contains(phrase) ? phrase : nil
    }

    private static func command(_ after: String) -> WakeCommand {
        let rest = String(after.drop { $0.isWhitespace || $0.isPunctuation }).trimmingCharacters(in: .whitespacesAndNewlines)
        let restRange = NSRange(rest.startIndex..., in: rest)
        if rest.isEmpty { return .listen }
        if stopNotes.firstMatch(in: rest, range: restRange) != nil { return .stopNotes }
        if startNotes.firstMatch(in: rest, range: restRange) != nil { return .startNotes }
        if sleep.firstMatch(in: rest, range: restRange) != nil { return .sleep }
        return .ask(rest)
    }
}
