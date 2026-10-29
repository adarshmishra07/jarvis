import Foundation

/// Who said a line: you (the mic) or the others (the Mac's sound, such as a call).
public enum Side: String, Codable, Sendable { case me = "Me", them = "Them" }

public struct MeetingLine: Codable, Equatable, Sendable {
    public let at: Date
    public let speaker: Side
    public let text: String
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
