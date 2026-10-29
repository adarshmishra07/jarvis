import Foundation

public enum CompanionError: Error, Equatable {
    case offline
    case dropped
}

/// Talks to the companion over a Unix socket: one connection per request, newline-delimited JSON.
public final class CompanionClient: @unchecked Sendable {
    public let socketPath: String
    private let queue = DispatchQueue(label: "companion-client", attributes: .concurrent)

    public init(socketPath: String) { self.socketPath = socketPath }

    public func send(_ request: Request, id: String = UUID().uuidString) -> AsyncThrowingStream<Event, Error> {
        let payload = request.json(id: id)
        return AsyncThrowingStream { continuation in
            let path = socketPath
            let socket = SocketBox()
            // Abandoned (for example, an interrupted answer): close the connection so the companion stops working on it.
            continuation.onTermination = { _ in socket.shutdown() }
            queue.async {
                guard let fd = Self.connect(path) else { continuation.finish(throwing: CompanionError.offline); return }
                defer { socket.clear(); close(fd) } // cleared first, so a late shutdown never hits a reused descriptor
                guard socket.set(fd) else { return } // abandoned before it connected
                guard var line = try? JSONSerialization.data(withJSONObject: payload) else { continuation.finish(throwing: CompanionError.dropped); return }
                line.append(0x0A)
                let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
                guard written == line.count else { continuation.finish(throwing: CompanionError.dropped); return }

                var pending = Data()
                var chunk = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n <= 0 { continuation.finish(throwing: CompanionError.dropped); return }
                    pending.append(contentsOf: chunk[0..<n])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let lineData = pending[pending.startIndex..<newline]
                        pending.removeSubrange(pending.startIndex...newline)
                        guard let event = Event(line: Data(lineData)), event.id == id else { continue }
                        continuation.yield(event)
                        if event.isFinal { continuation.finish(); return }
                    }
                }
            }
        }
    }

    /// The final event of a request that streams nothing else.
    public func call(_ request: Request) async throws -> Event {
        var last: Event?
        for try await event in send(request) { last = event }
        guard let last else { throw CompanionError.dropped }
        return last
    }

    private static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }
}

/// The open socket of one request, so an abandoned stream can shut it from another thread.
private final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    private var gone = false

    /// False when the stream was already abandoned.
    func set(_ fd: Int32) -> Bool { lock.withLock { self.fd = fd; return !gone } }

    func clear() { lock.withLock { fd = nil } }

    /// Unblocks the reader; the reading loop then sees end of stream and closes the socket.
    func shutdown() { lock.withLock { gone = true; if let fd { _ = Darwin.shutdown(fd, SHUT_RDWR) } } }
}
