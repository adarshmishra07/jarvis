import Foundation

/// Questions the Mac can answer on its own (the time, the date, the day), answered at once instead of online.
/// Only the whole question counts: "what time is my meeting" still goes to Jarvis.
public enum QuickAnswer {
    private enum Kind { case time, date, day }

    private static let patterns: [(Kind, NSRegularExpression)] = [
        (.time, #"what time is it|(tell me )?what'?s the time|(tell me )?what is the time|(tell me )?the time|(i )?(want|wanting|need) to know the time|(i )?(am|'m) wanting to know the time|current time|time|kitne baje (hain|hai|he)|kitna baja (hai|he)|(time|samay) kya (hai|hua)|kya time (hai|hua)|कितने बजे (हैं|है)|(समय|टाइम) क्या (है|हुआ)"#),
        (.date, #"what'?s the date|what is the date|what'?s today'?s date|what is today'?s date|today'?s date|(the )?date|aaj ki date( kya hai)?|aaj kya date hai|आज की (तारीख|डेट) क्या है|आज (क्या )?(तारीख|डेट) है"#),
        (.day, #"what day is (it|today)|what'?s the day|aaj kaun ?sa din hai|आज कौन सा दिन है"#),
    ].map { kind, body in (kind, try! NSRegularExpression(pattern: "^(?:\(body))( now| today| right now)?$")) }

    /// Filler that does not change the question: who it is addressed to and how politely.
    private static let filler = try! NSRegularExpression(pattern: #"^((hey |hi |hello |ok |okay )?(pika|jarvis) |please |can you |could you |pls |yes |yeah |ok |okay |so )+|( please| pls)$"#)

    public static func reply(to question: String, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        var text = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet(charactersIn: "?!.,।")).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = filler.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let kind = patterns.first(where: { $0.1.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil })?.0 else { return nil }
        let hindi = text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        switch kind {
        case .time:
            format.dateFormat = hindi ? "h:mm" : "h:mm a"
            return hindi ? "अभी \(format.string(from: now)) बजे हैं।" : "It's \(format.string(from: now))."
        case .date:
            format.dateFormat = "EEEE, d MMMM"
            return "It's \(format.string(from: now))."
        case .day:
            format.dateFormat = "EEEE"
            return "It's \(format.string(from: now))."
        }
    }
}
