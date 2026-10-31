import Foundation

public typealias JSON = [String: Any]

/// One line of the companion's reply stream.
public struct Event {
    public let id: String
    public let type: String
    public let body: JSON

    public init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? JSON,
              let id = object["id"] as? String, let type = object["type"] as? String else { return nil }
        self.id = id; self.type = type; self.body = object
    }

    public var text: String? { body["text"] as? String }
    public var isFinal: Bool { type == "result" || type == "error" }
    public var errorCode: String? { type == "error" ? body["code"] as? String : nil }
}

public enum Request {
    case ask(question: String, contexts: [String], history: [[String: String]] = [], voice: Bool = false, summary: String = "", files: [[String: Any]] = [])
    case ingest(text: String, clipId: String)
    case graph
    case forget(segmentId: Int)
    case forgetMeeting(id: String)
    case setup
    case setKey(name: String, value: String)
    case notes(contexts: [String])
    case restore(segmentId: Int)
    case importText(name: String, text: String)
    case approve(approvalId: String, ok: Bool)
    case connectors
    case apps
    case connectApp(toolkit: String, alias: String)
    case removeApp(toolkit: String, accountId: String)
    case renameApp(toolkit: String, accountId: String, alias: String)
    case addMcp(name: String, url: String, headerName: String, headerValue: String)
    case removeMcp(name: String)
    case skills
    case installSkill(source: String)
    case setSkill(name: String, enabled: Bool?, autoRun: Bool?)
    case removeSkill(name: String)
    case mcpSignIn(name: String)
    case watchBrowser
    case watchTasks
    case cancelTask(id: String)
    case reminder(id: Int, action: String, minutes: Int)
    case meetingNote(id: String, lines: [[String: Any]], started: String)
    case update
    case image(url: String, clicked: Bool)
    case browserInput([String: Any])
    case browserResume(note: String)
    case todos(contexts: [String])
    case setTodo(Int, status: String)
    case ledger(limit: Int)
    case status
    case setPause(Bool)
    case setInstructions([String])
    case feedback(rating: String, question: String, answer: String, model: String)

    public func json(id: String) -> JSON {
        switch self {
        case let .ask(question, contexts, history, voice, summary, files):
            return ["id": id, "type": "ask", "question": question, "contexts": contexts, "history": history, "voice": voice]
                .merging(summary.isEmpty ? [:] : ["summary": summary]) { a, _ in a }.merging(files.isEmpty ? [:] : ["files": files]) { a, _ in a }
        case let .ingest(text, clipId): return ["id": id, "type": "ingest", "text": text, "clipId": clipId]
        case .graph: return ["id": id, "type": "graph"]
        case let .forget(segmentId): return ["id": id, "type": "forget", "segmentId": segmentId]
        case let .forgetMeeting(mid): return ["id": id, "type": "forgetMeeting", "meetingId": mid]
        case .setup: return ["id": id, "type": "setup"]
        case let .setKey(name, value): return ["id": id, "type": "setKey", "name": name, "value": value]
        case let .approve(approvalId, ok): return ["id": id, "type": "approve", "approvalId": approvalId, "ok": ok]
        case .connectors: return ["id": id, "type": "connectors"]
        case .apps: return ["id": id, "type": "apps"]
        case let .connectApp(toolkit, alias): return ["id": id, "type": "connectApp", "toolkit": toolkit, "alias": alias]
        case let .removeApp(toolkit, accountId): return ["id": id, "type": "removeApp", "toolkit": toolkit, "accountId": accountId]
        case let .renameApp(toolkit, accountId, alias): return ["id": id, "type": "renameApp", "toolkit": toolkit, "accountId": accountId, "alias": alias]
        case let .addMcp(name, url, headerName, headerValue):
            return ["id": id, "type": "addMcp", "name": name, "url": url, "headerName": headerName, "headerValue": headerValue]
        case let .removeMcp(name): return ["id": id, "type": "removeMcp", "name": name]
        case .skills: return ["id": id, "type": "skills"]
        case let .installSkill(source): return ["id": id, "type": "installSkill", "source": source]
        case let .setSkill(name, enabled, autoRun):
            var j: JSON = ["id": id, "type": "setSkill", "name": name]
            if let enabled { j["enabled"] = enabled }
            if let autoRun { j["autoRun"] = autoRun }
            return j
        case let .removeSkill(name): return ["id": id, "type": "removeSkill", "name": name]
        case let .mcpSignIn(name): return ["id": id, "type": "mcpSignIn", "name": name]
        case .watchBrowser: return ["id": id, "type": "watchBrowser"]
        case .update: return ["id": id, "type": "update"]
        case .watchTasks: return ["id": id, "type": "watchTasks"]
        case let .cancelTask(taskId): return ["id": id, "type": "cancelTask", "taskId": taskId]
        case let .meetingNote(mid, lines, started): return ["id": id, "type": "meetingNote", "meetingId": mid, "lines": lines, "started": started]
        case let .reminder(rid, action, minutes): return ["id": id, "type": "reminder", "reminderId": rid, "action": action, "minutes": minutes]
        case let .image(url, clicked): return ["id": id, "type": "image", "url": url, "clicked": clicked]
        case let .browserInput(input): return ["id": id, "type": "browserInput", "input": input]
        case let .browserResume(note): return ["id": id, "type": "browserResume", "note": note]
        case let .importText(name, text): return ["id": id, "type": "importText", "name": name, "text": text]
        case let .restore(segmentId): return ["id": id, "type": "restore", "segmentId": segmentId]
        case let .notes(contexts): return ["id": id, "type": "notes", "contexts": contexts, "limit": 500]
        case let .todos(contexts): return ["id": id, "type": "todos", "contexts": contexts]
        case let .setTodo(todoId, status): return ["id": id, "type": "todo", "todoId": todoId, "status": status]
        case let .ledger(limit): return ["id": id, "type": "ledger", "limit": limit]
        case .status: return ["id": id, "type": "status"]
        case let .setPause(on): return ["id": id, "type": "settings", "pauseCloud": on]
        case let .setInstructions(list): return ["id": id, "type": "settings", "instructions": list]
        case let .feedback(rating, question, answer, model): return ["id": id, "type": "feedback", "rating": rating, "question": question, "answer": answer, "model": model]
        }
    }
}
