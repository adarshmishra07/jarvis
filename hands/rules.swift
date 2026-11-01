// The same never-list as the companion (companion/src/never.json, copied into this app when it is built), matched the
// same way as companion/src/never.ts. scripts/check-hands-rules.sh runs the shared cases against this file.
import Foundation

struct Rules: Sendable {
    let lists: [(kind: String, phrases: [[String]])]
    let moneySites: Set<String>
    let numbers: NSRegularExpression
    let dates: NSRegularExpression
    let minDigits: Int
    let personal: [NSRegularExpression]

    init(json: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let n = o["numbers"] as? [String: Any], let pattern = n["pattern"] as? String, let min = n["minDigits"] as? Int, let dates = n["dates"] as? String else {
            throw Failure(message: "never.json is unreadable")
        }
        lists = ["delete", "money", "send"].map { k in (k, (o[k] as? [String] ?? []).map { $0.split(separator: " ").map(String.init) }) }
        moneySites = Set(o["moneySites"] as? [String] ?? [])
        numbers = try NSRegularExpression(pattern: pattern)
        self.dates = try NSRegularExpression(pattern: dates)
        minDigits = min
        personal = try (o["personal"] as? [String] ?? []).map { try NSRegularExpression(pattern: $0) }
    }

    /// Lowercase words, with camelCase and snake_case split.
    static func words(_ text: String) -> [String] {
        let split = text.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
        return split.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted).filter { !$0.isEmpty }
    }
    static func same(_ w: String, _ p: String) -> Bool {
        w == p || ["s", "es", "d", "ed", "ing"].contains { w == p + $0 } || (p.hasSuffix("e") && w == p.dropLast() + "ing")
    }

    /// "delete", "money" or "send" when this label would do one of them.
    func never(_ text: String) -> String? {
        let ws = Self.words(text)
        for (kind, phrases) in lists {
            for ps in phrases where ws.indices.contains(where: { i in ps.indices.allSatisfy { j in i + j < ws.count && Self.same(ws[i + j], ps[j]) } }) { return kind }
        }
        return nil
    }

    func personal(_ text: String) -> Bool {
        let all = NSRange(text.startIndex..., in: text)
        let plain = dates.stringByReplacingMatches(in: text, range: all, withTemplate: " ") // dates and times are not phone numbers
        for m in numbers.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            if let r = Range(m.range, in: plain), plain[r].filter(\.isNumber).count >= minDigits { return true }
        }
        return personal.contains { $0.firstMatch(in: text, range: all) != nil }
    }

    func moneySite(_ url: URL) -> Bool {
        let parts = (url.host ?? "").lowercased().split(separator: ".").map(String.init)
            + url.path.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.contains(where: moneySites.contains)
    }
}

let refusedWhat = ["delete": "deletes anything", "money": "buys, pays or does anything with money", "send": "sends, posts, shares or uploads anything"]
func refusal(_ kind: String) -> Failure {
    Failure(message: "Refused: Jarvis never \(refusedWhat[kind] ?? kind), and no one can approve it. Do not try another way. Tell the user exactly what is ready and that this last step is theirs to do.")
}
