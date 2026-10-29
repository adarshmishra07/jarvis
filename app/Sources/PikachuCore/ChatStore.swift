import Foundation

public struct SavedChat: Codable, Equatable {
    public var id: UUID
    public var title: String
    public var updated: Date
    public var turns: [ChatTurn]
    /// The running summary of turns up to and including `summarizedThrough` (the chat never ends).
    public var summary: String? = nil
    public var summarizedThrough: UUID? = nil
}

public struct ChatSummary: Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let updated: Date
}

/// Past chats, one JSON file each, in the app's own container. Nothing leaves the Mac.
/// ponytail: list() reads every file; add an index file if there are ever thousands of chats.
public final class ChatStore: @unchecked Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private func file(_ id: UUID) -> URL { fileURL(id) }

    public func exists(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: file(id).path) }

    /// Moves a file that could not be read out of the way (kept beside it), so it is never overwritten.
    public func setAside(_ id: UUID) {
        let target = file(id).appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: file(id), to: target)
    }

    public func save(_ chat: SavedChat) {
        guard let data = try? JSONEncoder().encode(chat) else { return }
        try? data.write(to: file(chat.id), options: [.atomic, .completeFileProtection])
    }

    public func load(_ id: UUID) -> SavedChat? {
        (try? Data(contentsOf: file(id))).flatMap { try? JSONDecoder().decode(SavedChat.self, from: $0) }
    }

    public func list() -> [ChatSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(SavedChat.self, from: $0) } }
            .map { ChatSummary(id: $0.id, title: $0.title, updated: $0.updated) }
            .sorted { $0.updated > $1.updated }
    }

    public func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }
}
