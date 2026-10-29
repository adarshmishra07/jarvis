import XCTest
@testable import PikachuCore

/// A throwaway server: accepts one connection, reads the request line, then writes `reply` in two pieces.
private func fakeServer(path: String, reply: [Data], dropAfter: Bool = false) {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    listen(fd, 1)
    DispatchQueue.global().async {
        let c = accept(fd, nil, nil)
        var buf = [UInt8](repeating: 0, count: 4096)
        _ = read(c, &buf, buf.count)
        for piece in reply { piece.withUnsafeBytes { _ = write(c, $0.baseAddress, piece.count) }; usleep(20_000) }
        close(c); close(fd)
    }
}

final class CompanionClientTests: XCTestCase {
    private func path() -> String { "/tmp/pk-\(UUID().uuidString.prefix(8)).sock" }

    func testOfflineWhenSocketMissing() async {
        let client = CompanionClient(socketPath: "/tmp/does-not-exist.sock")
        do { _ = try await client.call(.status); XCTFail("expected offline") }
        catch { XCTAssertEqual(error as? CompanionError, .offline) }
    }

    func testStreamsEventsInOrderAcrossSplitChunksWithHindiAndNewlines() async throws {
        let p = path()
        let client = CompanionClient(socketPath: p)
        let id = "fixed-id"
        let sentence = #"{"id":"fixed-id","type":"sentence","text":"नमस्ते\nline two"}"# + "\n"
        let result = #"{"id":"fixed-id","type":"result","ok":true}"# + "\n"
        let bytes = Data((sentence + result).utf8)
        fakeServer(path: p, reply: [bytes.prefix(20), bytes.dropFirst(20)])
        var got: [Event] = []
        for try await e in client.send(.status, id: id) { got.append(e) }
        XCTAssertEqual(got.map(\.type), ["sentence", "result"])
        XCTAssertEqual(got[0].text, "नमस्ते\nline two")
    }

    func testDroppedMidStreamFinishesWithError() async {
        let p = path()
        let client = CompanionClient(socketPath: p)
        fakeServer(path: p, reply: [Data(#"{"id":"x","type":"sentence","text":"hi"}"#.utf8 + [0x0A])])
        do { for try await _ in client.send(.status, id: "x") {}; XCTFail("expected drop") }
        catch { XCTAssertEqual(error as? CompanionError, .dropped) }
    }

    func testAbandoningAStreamClosesTheConnectionSoTheCompanionStops() async throws {
        let p = path()
        unlink(p)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(p.utf8) + [0]) }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        Darwin.listen(fd, 1)
        let closed = expectation(description: "server sees the client leave")
        DispatchQueue.global().async {
            let c = Darwin.accept(fd, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(c, &buf, buf.count)
            let line = Data(#"{"id":"x","type":"sentence","text":"hi"}"#.utf8 + [0x0A])
            line.withUnsafeBytes { _ = Darwin.write(c, $0.baseAddress, line.count) }
            if Darwin.read(c, &buf, buf.count) <= 0 { closed.fulfill() } // blocks until the client goes
            Darwin.close(c); Darwin.close(fd)
        }
        let client = CompanionClient(socketPath: p)
        let task = Task { for try await _ in client.send(.status, id: "x") {} }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await fulfillment(of: [closed], timeout: 2)
    }
}
