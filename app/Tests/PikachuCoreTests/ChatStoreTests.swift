import XCTest
@testable import PikachuCore

private struct Echo: CompanionAPI {
    func send(_ request: Request, id: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { c in
            let body: JSON = ["id": "1", "type": "token", "text": "Sure."]
            c.yield(Event(line: try! JSONSerialization.data(withJSONObject: body))!)
            c.yield(Event(line: try! JSONSerialization.data(withJSONObject: ["id": "1", "type": "result"]))!)
            c.finish()
        }
    }
}

@MainActor
final class ChatStoreTests: XCTestCase {
    private func tempStore() -> ChatStore {
        ChatStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)"))
    }

    func testItIsOneChatThatCarriesOnAfterARestart() async {
        let store = tempStore()
        let m = AppModel(api: Echo(), store: store)
        m.question = "When is the Orbit launch?"; await m.ask()
        let again = AppModel(api: Echo(), store: store)
        XCTAssertEqual(again.chat.map(\.text), ["When is the Orbit launch?", "Sure."])
        again.question = "And who owns it?"; await again.ask()
        XCTAssertEqual(store.load(AppModel.foreverId)?.turns.count, 4)
    }

    func testOlderChatsAreMergedOldestFirstAndTheirFilesKept() {
        let store = tempStore()
        func saved(_ text: String, _ day: Double) -> SavedChat {
            var t = ChatTurn(role: "user", text: text); t.at = Date(timeIntervalSince1970: day * 86400)
            return SavedChat(id: UUID(), title: text, updated: Date(timeIntervalSince1970: day * 86400), turns: [t, ChatTurn(role: "assistant", text: "ok")])
        }
        store.save(saved("newer", 2)); store.save(saved("older", 1))
        let m = AppModel(api: Echo(), store: store)
        XCTAssertEqual(m.chat.map(\.text), ["older", "ok", "newer", "ok"])
        XCTAssertEqual(store.list().count, 3, "the old chats stay on disk as they were")
    }

    func testAChatFileThatCannotBeReadIsKeptAsideNotOverwritten() {
        let store = tempStore()
        let dir = FileManager.default.temporaryDirectory
        _ = dir
        let url = store.fileURL(AppModel.foreverId)
        try? Data("not json".utf8).write(to: url)
        var old = ChatTurn(role: "user", text: "older chat"); old.at = Date(timeIntervalSince1970: 0)
        store.save(SavedChat(id: UUID(), title: "old", updated: Date(timeIntervalSince1970: 0), turns: [old]))
        let m = AppModel(api: Echo(), store: store)
        XCTAssertTrue(m.chat.isEmpty, "nothing is merged over a chat that exists but could not be read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".unreadable"), "the unreadable file is kept for recovery")
    }

    func testAnEmptyChatIsNeverSaved() {
        let store = tempStore()
        _ = AppModel(api: Echo(), store: store)
        XCTAssertEqual(store.list().count, 0)
    }

    func testOnlyTheLastRoundsAreShownAndTheRestCounted() {
        let turns = (1...12).flatMap { n in [ChatTurn(role: "user", text: "q\(n)"), ChatTurn(role: "assistant", text: "a\(n)")] }
        let page = AppModel.recent(turns, rounds: 10)
        XCTAssertEqual(page.turns.first?.text, "q3")
        XCTAssertEqual(page.turns.count, 20)
        XCTAssertEqual(page.hiddenRounds, 2)
        XCTAssertEqual(AppModel.recent(turns, rounds: 20).hiddenRounds, 0)
    }

    func testAChatSavedByAnOlderVersionStillOpens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)")
        let store = ChatStore(directory: dir)
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","title":"Hi","updated":0,"turns":[{"id":"\#(UUID().uuidString)","role":"user","text":"Hi","citations":[],"meta":"","failed":false}]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("\(id.uuidString).json"))
        XCTAssertEqual(store.list().map(\.title), ["Hi"])
        XCTAssertEqual(store.load(id)?.turns.first?.text, "Hi")
    }
}
