import Foundation

/// Who said a line: you (the mic) or the others (the Mac's sound, such as a call).
public enum Side: String, Codable, Sendable { case me = "Me", them = "Them" }

public struct MeetingLine: Codable, Equatable, Sendable {
    public let at: Date
    public let speaker: Side
    public let text: String
}

/// Without headphones the mic hears the call from the speakers, so the other side's words come back as your own line.
/// The loudness check (EchoFilter) misses most of them (37% of "Me" lines in a real call were echoes, 30 Oct 2026):
/// a mic line that says nearly the same as a call line a few seconds apart is that echo.
public enum EchoText {
    static let window: TimeInterval = 15 // echoes landed up to 12 s before and 4 s after the call's own line
    static let sameShare = 0.6

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
    }

    /// Whether two lines say the same thing: most of their words are shared. Lines under three words never match.
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard min(x.count, y.count) >= 3 else { return false }
        return Double(x.intersection(y).count) / Double(max(x.count, y.count)) >= sameShare
    }
}

/// A note-taking session: the whole transcript, and the note written from it when it stops.
public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let started: Date
    public var ended: Date?
    public var lines: [MeetingLine] = []
    public var title: String?
    /// Summary, decisions and action items (Markdown). Nil until written; it can be written later if it failed.
    public var note: String?

    public init(id: UUID = UUID(), started: Date = Date()) { self.id = id; self.started = started }
}

extension Meeting {
    /// Adds a line unless it is the call heard again through the mic; a call line also removes your lines that echoed it.
    public mutating func add(_ line: MeetingLine) {
        let near = { (other: MeetingLine) in abs(other.at.timeIntervalSince(line.at)) <= EchoText.window }
        switch line.speaker {
        case .me:
            if lines.contains(where: { $0.speaker == .them && near($0) && EchoText.same($0.text, line.text) }) { return }
        case .them:
            lines.removeAll { $0.speaker == .me && near($0) && EchoText.same($0.text, line.text) }
        }
        lines.append(line)
    }
}

public typealias NoteSession = Meeting

/// Meetings, one JSON file each, in the app's own container. Saved after every line, so nothing is lost mid-meeting.
/// ponytail: rewrites the whole file per line; fine for meetings of a few thousand lines, append-only if ever longer.
public final class MeetingStore: @unchecked Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ meeting: Meeting) {
        guard let data = try? JSONEncoder().encode(meeting) else { return }
        try? data.write(to: file(meeting.id), options: [.atomic, .completeFileProtection])
    }

    /// Newest first.
    public func list() -> [Meeting] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Meeting.self, from: $0) } }
            .sorted { $0.started > $1.started }
    }

    public func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }
}
