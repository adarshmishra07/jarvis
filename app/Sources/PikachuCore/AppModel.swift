import Foundation
import Combine

public protocol CompanionAPI: Sendable {
    func send(_ request: Request, id: String) -> AsyncThrowingStream<Event, Error>
}

extension CompanionClient: CompanionAPI {}

public struct ChatTurn: Identifiable, Equatable, Codable {
    public var id = UUID()
    public let role: String // "user" or "assistant"
    public var text: String
    public var citations: [String] = []
    public var meta = ""
    public var failed = false
    /// What this turn taught the memory, e.g. "Saved to company, replaced 1 older note".
    public var learned: String?
    /// The model that answered, and the user's "up" or "down" on it.
    public var model = ""
    public var rating: String?
    /// Pictures a connected app returned with this answer.
    public var images: [Data] = []
    /// You started talking over this answer.
    public var interrupted = false
    /// When it was said.
    public var at = Date()
    /// The tool steps behind this answer, from the companion, sent back with later questions so it can carry on.
    public var work: String?
    /// Names of the files you attached to this message (the files themselves are sent once, not kept).
    public var attachments: [String] = []
    /// For a background task's report: which task, so it is added only once.
    public var taskId: String?

    public init(role: String, text: String) { self.role = role; self.text = text }

    private enum CodingKeys: String, CodingKey { case id, role, text, citations, meta, failed, learned, model, rating, interrupted, at, images, work, attachments, taskId }

    /// Every field but role and text may be missing: chats saved by older versions still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        citations = try c.decodeIfPresent([String].self, forKey: .citations) ?? []
        meta = try c.decodeIfPresent(String.self, forKey: .meta) ?? ""
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        learned = try c.decodeIfPresent(String.self, forKey: .learned)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        rating = try c.decodeIfPresent(String.self, forKey: .rating)
        interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        images = try c.decodeIfPresent([Data].self, forKey: .images) ?? []
        work = try c.decodeIfPresent(String.self, forKey: .work)
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
    }
}

/// A file waiting to go with the next question: its bytes, or for audio and video the transcript made on this Mac.
public struct Attached: Equatable, Identifiable {
    public let id = UUID()
    public let name: String
    public let data: Data
    public let transcript: Bool
    public init(name: String, data: Data, transcript: Bool = false) { self.name = name; self.data = data; self.transcript = transcript }
}

/// A long job Jarvis handed to a helper. Its report goes into the chat when it ends.
public struct BackgroundTask: Equatable, Identifiable {
    public let id: String
    public let goal: String
    public let status: String // running, done, failed or cancelled
    public let steps: Int
}

public struct Approval: Equatable, Identifiable {
    public let id: String
    public let action: String
    /// Asked by a background task (it stays until answered; a new chat question does not replace it).
    public let background: Bool
}

public struct UpdateInfo: Equatable {
    public let installed: String
    public let ready: Bool
    public let version: String
    /// What changed, one line per change.
    public let notes: [String]
}

/// "Saved to company" plus how many older notes the new one replaced.
func savedText(context: String, replaced: Int) -> String {
    "Saved to \(context)" + (replaced > 0 ? ", replaced \(replaced) older note\(replaced == 1 ? "" : "s")" : "")
}

public struct ToolStep: Equatable { public let name: String, detail: String }

/// What the last answer did, step by step, for the live view: memory nodes walked, web searched, model used.
public struct Trace: Equatable {
    public var stages: [String] = []
    public var nodes: [Int] = []
    public var notes = 0
    public var queries: [String] = []
    /// Web sources by host name.
    public var sources: [String] = []
    public var model = ""
    /// Tool steps in order: the browser or an app, and what it touched.
    public var tools: [ToolStep] = []
    public var done = false
    /// When each stage arrived, so the view can animate from it.
    public var times: [String: Date] = [:]
    public init() {}
}

public struct NoteRow: Identifiable, Equatable {
    public let id: Int
    public let summary: String, context: String, createdAt: String
    /// When it happened (YYYY, YYYY-MM or YYYY-MM-DD), or empty when the note gives no time.
    public let happened: String
    public let replaced: Bool
}

public struct TodoRow: Identifiable, Equatable {
    public let id: Int
    public let text: String, owner: String?, context: String, createdAt: String
    public var status: String // open, done or dropped
}

public struct AppAccount: Equatable, Identifiable {
    public let id: String; public let status: String; public let alias: String
    /// Which account it is (its email or user name), as the app reports it.
    public var who = ""
    /// Your label and the account's email, so two accounts of one app can be told apart.
    public var label: String { [alias, who].filter { !$0.isEmpty }.joined(separator: "  ·  ") }
}
/// A key Jarvis uses and whether it is set; the value itself never leaves the companion.
public struct SetupKey: Equatable, Identifiable {
    public let name: String, purpose: String
    public let required: Bool, set: Bool
    public var id: String { name }
}

public struct AppRow: Equatable, Identifiable {
    public let slug: String, name: String, group: String, about: String
    public let connected: Bool
    public let accounts: [AppAccount]
    public var id: String { slug }
}

/// What Jarvis's browser shows and who is in control: "idle", "working" (watch only) or "needsUser" (your turn).
public struct BrowserView: Equatable {
    public var state = "idle"
    public var reason = ""
    public var url = ""
    public var frame: Data?
    public init() {}
}

/// An image link in an answer, as the companion judged it.
public enum ImageLoad: Equatable { case ready(Data), ask, blocked(String) }

public struct LedgerRow: Identifiable, Equatable {
    public let id = UUID()
    public let ts: String, method: String, host: String, path: String
    public let bytes: Int, status: Int
}

@MainActor
public final class AppModel: ObservableObject {
    public static let allSpaces = ["company", "professional", "personal"]

    @Published public var connected = false
    @Published public var asking = false
    @Published public var question = ""
    /// The conversation. The last assistant turn fills in word by word while it streams.
    @Published public var chat: [ChatTurn] = []
    @Published public var notice: String?
    @Published public var pauseCloud = false
    @Published public var spaces: Set<String> = ["company", "professional"] // personal stays off until asked for
    @Published public var counts = (segments: 0, entities: 0)
    /// Names and terms from the companion, used to help speech-to-text spell them.
    @Published public var vocabulary: [String] = []
    /// Learned spelling fixes, applied to speech before it is shown or sent.
    @Published public var spellings: [String: String] = [:]
    /// How the user asked Jarvis to reply, learned from chat. Removable in Settings.
    @Published public var instructions: [String] = []
    /// The last nightly memory clean-up, as a line for the Memory screen.
    @Published public var lastCleanup: String?
    /// "Importing team.md: 4 of 12" while a file is being imported.
    @Published public var importProgress: String?
    @Published public var ledger: [LedgerRow] = []
    @Published public var graph: GraphData?
    /// Every note in the open spaces, newest first, for review and Forget.
    @Published public var notes: [NoteRow] = []
    @Published public var todos: [TodoRow] = []
    @Published public private(set) var noteSession: NoteSession?
    public var openTodos: Int { todos.filter { $0.status == "open" }.count }
    /// Past meetings, newest first.
    @Published public private(set) var meetings: [Meeting] = []
    private let meetingStore: MeetingStore?
    /// "Listening", "Transcribing" or nil. Shown by the orb.
    @Published public var voiceStatus: String?
    /// Hands-free conversation is on.
    @Published public var live = false
    /// Listening for "Hey Jarvis" while nothing else uses the mic. On unless you switch it off.
    /// How speech-to-text writes your own "Hey Jarvis", learned in training, so it wakes the way you say it.
    @Published public var wakeLearned = UserDefaults.standard.stringArray(forKey: "wakeLearned") ?? [] {
        didSet { UserDefaults.standard.set(wakeLearned, forKey: "wakeLearned") }
    }
    /// Wake word training in progress: what was heard for each try so far.
    @Published public var training: [String]?
    public var onTrainWake: (() -> Void)?
    @Published public var wakeWord = UserDefaults.standard.object(forKey: "wakeWord") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord") }
    }
    @Published public var trace = Trace()
    /// A step Jarvis wants to take that needs your yes (buy, send, delete...).
    /// Requests for your yes, oldest first: the chat's and background tasks' each wait their turn.
    @Published public private(set) var approvals: [Approval] = []
    public var pendingApproval: Approval? { approvals.first }

    private func addApproval(_ body: JSON, background: Bool) {
        guard let id = body["approvalId"] as? String else { return }
        approvals.removeAll { $0.id == id }
        approvals.append(Approval(id: id, action: body["action"] as? String ?? "", background: background))
    }
    /// The latest screenshot of Jarvis's browser, while it works.
    @Published public var browserShot: Data?
    /// Jarvis's browser as the app's window shows it.
    @Published public var browser = BrowserView()
    /// MCP servers (Composio and your own) and how many tools each offers.
    @Published public var connectors: [(name: String, tools: Int, url: String, needsSignIn: Bool)] = []
    @Published public var setupKeys: [SetupKey] = []
    /// Apps you can connect through Composio, with their accounts. Nil until loaded; empty with no Composio key.
    @Published public var apps: [AppRow]? = nil
    /// Opens a web page in your normal browser (Composio's sign-in).
    public var openURL: ((URL) -> Void)?
    /// The open chat and the saved ones, newest first.
    /// Called for each answer sentence as it streams, with the answer's turn id, so it can be spoken and then revealed.
    public var onSentence: ((String, UUID) -> Void)?
    /// Spoken answers already shown in full: sentences said after that are not added again.
    private var finished: Set<UUID> = []
    /// A reminder went off (id, text): the app notifies you, and says it if you are at the Mac.
    public var onReminder: ((Int, String) -> Void)?
    /// Jarvis switched something on the Mac during an answer ("startNotes", "stopNotes").
    public var onControl: ((String) -> Void)?
    /// Bumped by interrupt(): an answer from an older generation stops streaming and speaking.
    private var askGeneration = 0
    private var answering: (turn: UUID, task: Task<Void, Never>)?
    /// Mic buttons in the UI. `false` toggles talking to Jarvis, `true` toggles recording a note.
    public var onMicTap: ((_ note: Bool) -> Void)?
    /// Speaks a sample sentence in the chosen voice (Settings).
    public var onPreviewVoice: (() -> Void)?

    private let api: CompanionAPI
    private let store: ChatStore?

    /// Login details you typed in reply to Jarvis (only what looks like a secret). Never saved; scrubbed from the chat.
    private var sentSecrets: Set<String> = []

    /// Words around details in a reply ("my password is ..."), kept so the chat stays readable. Everything else counts.
    private static let filler: Set<String> = ["user", "username", "password", "passcode", "email", "login", "code", "the", "and", "for",
        "is", "my", "it", "its", "it's", "here", "this", "that", "use", "with", "account", "pin", "otp", "id", "name", "mail", "phone", "number"]

    /// A detail: looks like a secret (digits, symbols, mixed case) or is a long word (a lowercase password).
    /// Short everyday words ("logged in", a first name) stay, so the chat reads normally.
    private static func detail(_ word: String) -> Bool {
        !filler.contains(word.lowercased()) && (word.count >= 8 || (word.count >= 3
            && (word.contains(where: \.isNumber) || word.contains { !$0.isLetter && !$0.isNumber } || word.dropFirst().contains(where: \.isUppercase))))
    }

    private func remember(sent reply: String) {
        let words = reply.split { $0.isWhitespace || $0 == "," || $0 == ";" }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`():.")) }
        sentSecrets.formUnion(words.filter(Self.detail))
    }

    /// The text with every detail you sent replaced, as whole words only.
    public func scrubbed(_ text: String) -> String {
        sentSecrets.sorted { $0.count > $1.count }.reduce(text) { out, secret in
            out.replacingOccurrences(of: "(?<![\\w])\(NSRegularExpression.escapedPattern(for: secret))(?![\\w])", with: "[sent by the user]", options: .regularExpression)
        }
    }

    /// The installed version and any staged update (built, waiting for you to install).
    @Published public var update: UpdateInfo?

    /// Installs the staged update: Pikachu quits and reopens on the new version.
    public func installUpdate() async {
        notice = "Updating. Pikachu will close and reopen in a few seconds."
        _ = try? await call(.update)
    }

    /// Files attached to the next question.
    @Published public var attached: [Attached] = []
    /// Turns a picked or dropped file into something to send (converts pictures, transcribes audio). Set by the app.
    public var prepareFile: ((URL) async -> Attached?)?
    /// Attached files together may not pass this (the model's request limit leaves room for the rest).
    static let maxAttachedBytes = 30_000_000

    public func attach(_ urls: [URL]) async {
        for url in urls {
            let file = await (prepareFile ?? Self.readFile)(url)
            guard let file else { notice = "Could not read \(url.lastPathComponent)."; continue }
            guard attached.reduce(file.data.count, { $0 + $1.data.count }) <= Self.maxAttachedBytes else { notice = "That is more than 30 MB of files for one question."; continue }
            attached.append(file)
        }
    }

    /// The file as it is, read with the access you gave by picking or dropping it.
    static func readFile(_ url: URL) async -> Attached? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? Data(contentsOf: url)).map { Attached(name: url.lastPathComponent, data: $0) }
    }

    /// One chat, forever: older turns are folded into a running summary by the companion.
    public static let foreverId = UUID(uuidString: "00000000-0000-0000-0000-00000000F0F0")!
    /// Questions send at most this many recent turns; anything older reaches the answer through the summary.
    static let maxHistorySent = 60
    private var summary: String?
    private var summarizedThrough: UUID?

    public init(api: CompanionAPI, store: ChatStore? = nil, meetings: MeetingStore? = nil) {
        self.api = api; self.store = store; self.meetingStore = meetings
        // A meeting the app quit in the middle of (a crash, a restart) ends at its last line, so its notes can be written.
        for var cut in meetings?.list() ?? [] where cut.ended == nil {
            cut.ended = cut.lines.last?.at ?? cut.started
            meetings?.save(cut)
        }
        self.meetings = meetings?.list() ?? []
        guard let store else { return }
        if let saved = store.load(Self.foreverId) {
            chat = saved.turns; summary = saved.summary; summarizedThrough = saved.summarizedThrough
        } else if store.exists(Self.foreverId) {
            store.setAside(Self.foreverId) // unreadable: kept for recovery, never merged over or overwritten
        } else {
            // First run as one chat: earlier chats are joined oldest first; their own files are left as they were.
            chat = store.list().reversed().compactMap { store.load($0.id) }.flatMap(\.turns)
            persist()
        }
    }

    private func persist() {
        // Whatever reached the screen (streamed, spoken, cut short), details you sent for a login are never kept.
        if !sentSecrets.isEmpty { chat = chat.map { var t = $0; t.text = scrubbed(t.text); return t } }
        guard let store, chat.contains(where: { $0.role == "user" }) else { return }
        store.save(SavedChat(id: Self.foreverId, title: "Jarvis", updated: Date(), turns: chat, summary: summary, summarizedThrough: summarizedThrough))
    }

    /// The last `rounds` question-and-answer rounds, and how many earlier rounds are hidden.
    public static func recent(_ turns: [ChatTurn], rounds: Int) -> (turns: ArraySlice<ChatTurn>, hiddenRounds: Int) {
        let starts = turns.indices.filter { turns[$0].role == "user" }
        guard starts.count > rounds else { return (turns[...], 0) }
        return (turns[starts[starts.count - rounds]...], starts.count - rounds)
    }

    private func call(_ request: Request) async throws -> Event {
        var last: Event?
        for try await e in api.send(request, id: UUID().uuidString) { last = e }
        guard let last else { throw CompanionError.dropped }
        return last
    }

    public func refreshStatus() async {
        do {
            let e = try await call(.status)
            connected = true
            pauseCloud = e.body["pauseCloud"] as? Bool ?? false
            vocabulary = e.body["vocabulary"] as? [String] ?? vocabulary
            spellings = e.body["spellings"] as? [String: String] ?? spellings
            instructions = e.body["instructions"] as? [String] ?? instructions
            importProgress = (e.body["importing"] as? [String: Any]).map {
                let waiting = $0["waiting"] as? Int ?? 0
                return "Importing \($0["name"] as? String ?? "file"): \($0["done"] as? Int ?? 0) of \($0["total"] as? Int ?? 0)" + (waiting > 0 ? ", \(waiting) more file\(waiting == 1 ? "" : "s") waiting" : "")
            }
            update = (e.body["update"] as? [String: Any]).map {
                UpdateInfo(installed: $0["installed"] as? String ?? "", ready: $0["ready"] as? Bool ?? false, version: $0["version"] as? String ?? "", notes: $0["notes"] as? [String] ?? [])
            }
            if let c = e.body["lastCleanup"] as? [String: Any], let at = c["at"] as? String {
                lastCleanup = "Last clean-up \(at.prefix(10)): \(c["notesMerged"] as? Int ?? 0) duplicate notes replaced, \(c["entitiesMerged"] as? Int ?? 0) duplicate names merged."
            }
            if let c = e.body["counts"] as? [String: Any] { counts = (c["segments"] as? Int ?? 0, c["entities"] as? Int ?? 0) }
        } catch { connected = false }
    }

    /// `speak` is true when the question was spoken: the answer is read aloud and shown sentence by sentence as it is said.
    /// Jarvis asked you something mid-task (a login, a code): your next message is the reply.
    public var waitingForYou: Bool { browser.state == "needsUser" }

    public func ask(speak: Bool = false) async {
        let typed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = typed.isEmpty && !attached.isEmpty ? "Take a look at the attached \(attached.count == 1 ? "file" : "files")." : typed
        // A reply to Jarvis's question goes straight to it and is never saved in the chat (it may be a password).
        // While Jarvis waits on you, only a typed reply counts: speech is dropped, never sent or saved (it may be details).
        if waitingForYou, speak { question = ""; notice = "Type your reply to Jarvis."; return }
        if !typed.isEmpty, waitingForYou {
            question = ""
            remember(sent: typed)
            if await browserResume(typed) { notice = "Sent to Jarvis. Not saved in the chat." }
            else { question = typed; notice = "Could not reach Jarvis. Try again." }
            return
        }
        let files = attached
        guard !q.isEmpty || !files.isEmpty, !asking else { return }
        // The time, the date: the Mac knows, so the answer is instant and nothing goes online.
        if files.isEmpty, let quick = QuickAnswer.reply(to: q) {
            question = ""
            chat.append(ChatTurn(role: "user", text: q))
            let answer = ChatTurn(role: "assistant", text: speak ? "" : quick)
            chat.append(answer)
            if speak { onSentence?(quick, answer.id) }
            persist()
            return
        }

        asking = true; notice = nil; attached = []
        defer { asking = false }
        // Only turns after what the summary covers, each with its id so the companion can say how far it folded.
        let unfolded = summarizedThrough.flatMap { id in chat.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let history: [[String: String]] = chat[unfolded...].filter { !$0.failed && !$0.text.isEmpty }.suffix(Self.maxHistorySent)
            .map { t in ["role": t.role, "content": t.text + (t.attachments.isEmpty ? "" : "\n[attached: \(t.attachments.joined(separator: ", "))]"), "id": t.id.uuidString]
                .merging(t.work.map { ["work": $0] } ?? [:]) { a, _ in a } }
        var mine = ChatTurn(role: "user", text: q)
        mine.attachments = files.map(\.name)
        chat.append(mine)
        let answer = ChatTurn(role: "assistant", text: "")
        let aid = answer.id
        chat.append(answer)
        question = ""
        askGeneration += 1
        let generation = askGeneration
        trace = Trace(); browserShot = nil
        approvals.removeAll { !$0.background } // a new question replaces the last answer's requests, never a background task's
        defer { trace.done = true; persist() }
        let order = Self.allSpaces.filter(spaces.contains)
        var spoken: [String] = []
        // By id, not index: an interrupted, unanswered turn can be taken back while this is still running.
        func edit(_ change: (inout ChatTurn) -> Void) { if let i = chat.firstIndex(where: { $0.id == aid }) { change(&chat[i]) } }
        let work = Task { @MainActor in
        do {
            for try await e in api.send(.ask(question: q, contexts: order, history: history, voice: speak, summary: summary ?? "",
                                          files: files.map { ["name": $0.name, "data": $0.data.base64EncodedString(), "transcript": $0.transcript] }), id: UUID().uuidString) {
                guard generation == askGeneration, chat.contains(where: { $0.id == aid }) else { break } // interrupted
                switch e.type {
                case "token": if !speak, let t = e.text { edit { $0.text += t } }
                case "trace":
                    let stage = e.body["stage"] as? String ?? ""
                    trace.stages.append(stage); trace.times[stage] = Date()
                    switch stage {
                    case "memory": trace.nodes = e.body["nodes"] as? [Int] ?? []; trace.notes = e.body["notes"] as? Int ?? 0
                    case "web": trace.queries = e.body["queries"] as? [String] ?? []
                    case "sources": trace.sources = (e.body["sources"] as? [[String: Any]] ?? []).compactMap { $0["host"] as? String }
                    case "tool": trace.tools.append(ToolStep(name: e.body["name"] as? String ?? "", detail: e.body["detail"] as? String ?? ""))
                    case "answer": trace.model = (e.body["model"] as? String ?? "").replacingOccurrences(of: "claude-", with: "").uppercased()
                    default: break
                    }
                case "approval":
                    addApproval(e.body, background: false)
                case "control":
                    if let action = e.body["action"] as? String { onControl?(action) }
                case "image":
                    if let d = (e.body["data"] as? String).flatMap({ Data(base64Encoded: $0) }) { edit { $0.images.append(d) } }
                case "screenshot":
                    browserShot = (e.body["jpeg"] as? String).flatMap { Data(base64Encoded: $0) }
                case "sentence": if let t = e.text { spoken.append(t); if speak { onSentence?(t, aid) } }
                case "result":
                    if !speak { edit { if $0.text.isEmpty { $0.text = spoken.joined(separator: " ") } } }
                    // Keep the number the answer used ([8], [w1]) so the list matches the text.
                    let labels = (e.body["sources"] as? [[String: Any]])?.compactMap { src -> String? in
                        guard let label = src["label"] as? String else { return nil }
                        return (src["n"] as? String).map { "[\($0)] \(label)" } ?? label
                    }
                    let modelId = e.body["model"] as? String ?? ""
                    if let work = e.body["work"] as? String { edit { $0.work = work } }
                    if let s = e.body["summary"] as? String, let through = (e.body["foldedThrough"] as? String).flatMap(UUID.init(uuidString:)) {
                        summary = s; summarizedThrough = through
                    }
                    // The final answer (anything you sent for a login scrubbed out) replaces what was shown so far. A spoken
                    // one then stops growing sentence by sentence, so nothing shows twice, and it is never left blank
                    // if the app closes before every sentence is said.
                    if let final = e.body["answer"] as? String, !final.isEmpty {
                        edit { if !$0.interrupted { $0.text = final } }
                        finished.insert(aid)
                    }
                    var learned: [String] = []
                    if let s = e.body["spelling"] as? [String: String], let heard = s["heard"], let correct = s["correct"] {
                        learned.append("Learned: \(heard) is \(correct)")
                        spellings[heard.lowercased()] = correct
                    }
                    if e.body["instruction"] is String { learned.append("Will do from now on") }
                    if let saved = e.body["saved"] as? [String: Any], let ctx = saved["context"] as? String {
                        learned.append(savedText(context: ctx, replaced: saved["replaced"] as? Int ?? 0))
                    }
                    let meta = (e.body["ms"] as? [String: Any])?["total"] as? Int
                    edit {
                        $0.citations = labels ?? e.body["citations"] as? [String] ?? []
                        $0.model = modelId
                        if !learned.isEmpty { $0.learned = learned.joined(separator: "  /  ") }
                        if let meta { $0.meta = "\(modelId.replacingOccurrences(of: "claude-", with: "").uppercased())  /  \(meta) MS" }
                    }
                case "error":
                    edit { $0.text = e.body["message"] as? String ?? "Something went wrong."; $0.failed = true }
                default: break
                }
            }
            connected = true
        } catch CompanionError.offline {
            connected = false; edit { $0.text = "The companion is offline, so I cannot answer yet."; $0.failed = true }
            if attached.isEmpty { attached = files } // not sent: the files wait for the next try
        } catch {
            if generation == askGeneration { edit { $0.text = "The connection dropped. Try again."; $0.failed = true } }
        }
        }
        // Run as its own task so interrupt() can end it at once, which also closes the connection.
        answering = (aid, work)
        await work.value
        if answering?.turn == aid { answering = nil }
    }

    /// Adds a sentence to a spoken answer as it starts being heard, so the screen shows only what was said.
    public func reveal(_ turnId: UUID, _ sentence: String) {
        guard !finished.contains(turnId), let i = chat.firstIndex(where: { $0.id == turnId }) else { return }
        chat[i].text = chat[i].text.isEmpty ? sentence : chat[i].text + " " + sentence
    }

    /// Stops the answer being given now: no more of it is streamed or spoken (you started talking).
    public func interrupt() {
        askGeneration += 1
        guard let (turn, task) = answering else { return }
        if let i = chat.firstIndex(where: { $0.id == turn }) { chat[i].interrupted = true }
        task.cancel()
    }

    /// You said "stop": an interrupted answer that never started stays as stopped, so it is not merged into the next question.
    public func settleInterrupted() {
        guard let i = chat.indices.last, chat[i].role == "assistant", chat[i].interrupted, chat[i].text.isEmpty else { return }
        chat[i].text = "(stopped)"
        persist()
    }

    /// Takes back the last question if nothing of its answer was said yet, and returns it, so a sentence split by a
    /// pause can be sent again as one.
    public func retractUnanswered() -> String? {
        guard chat.count >= 2, let last = chat.last, last.role == "assistant", last.interrupted, last.text.isEmpty, !last.failed,
              chat[chat.count - 2].role == "user" else { return nil }
        let q = chat[chat.count - 2].text
        chat.removeLast(2)
        persist()
        return q
    }

    /// Saves a spoken or typed note to memory and says where it went.
    public func remember(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notice = "Saving note"
        do {
            let e = try await call(.ingest(text: t, clipId: "note-\(UUID().uuidString)"))
            if e.type == "error" { notice = e.body["message"] as? String ?? "Could not save the note."; return }
            notice = (e.body["kept"] as? Bool ?? false)
                ? "Note \(savedText(context: e.body["context"] as? String ?? "memory", replaced: e.body["replaced"] as? Int ?? 0).lowercased())."
                : "Not saved: nothing worth keeping, or it looked private."
            await refreshStatus()
        } catch { notice = "The companion is offline, so the note was not saved." }
    }

    /// Thumbs up or down on an answer. Stored by the companion as a local test case, with the question it answered.
    public func rate(_ turnId: UUID, up: Bool) async {
        guard let i = chat.firstIndex(where: { $0.id == turnId }), chat[i].role == "assistant", !chat[i].failed,
              let q = chat[..<i].last(where: { $0.role == "user" }) else { return }
        let rating = up ? "up" : "down"
        guard (try? await call(.feedback(rating: rating, question: q.text, answer: chat[i].text, model: chat[i].model)))?.type == "result" else { return }
        chat[i].rating = rating
        persist()
    }

    public func removeInstruction(_ text: String) async {
        let kept = instructions.filter { $0 != text }
        guard (try? await call(.setInstructions(kept)))?.type == "result" else { return }
        instructions = kept
    }

    public func setPause(_ on: Bool) async {
        pauseCloud = on
        _ = try? await call(.setPause(on))
    }

    /// Asks the device owner to confirm (Touch ID or password). Nil means no check, as in tests.
    public var authorize: ((_ reason: String) async -> Bool)?

    /// Personal memory needs Touch ID to switch on; switching anything off never asks.
    public func toggle(space: String) async {
        if spaces.contains(space) { spaces.remove(space); return }
        if space == "personal", let authorize, !(await authorize("show your personal memory")) { return }
        spaces.insert(space)
    }

    public func loadLedger() async {
        guard let e = try? await call(.ledger(limit: 100)), let rows = e.body["rows"] as? [[String: Any]] else { return }
        ledger = rows.map { LedgerRow(ts: $0["ts"] as? String ?? "", method: $0["method"] as? String ?? "", host: $0["host"] as? String ?? "", path: $0["path"] as? String ?? "", bytes: $0["bytes"] as? Int ?? 0, status: $0["status"] as? Int ?? 0) }
    }

    public func loadGraph() async {
        guard let e = try? await call(.graph) else { return }
        graph = GraphData(body: e.body)
    }

    public func loadTodos() async {
        guard let e = try? await call(.todos(contexts: Self.allSpaces.filter(spaces.contains))), let rows = e.body["todos"] as? [[String: Any]] else { return }
        todos = rows.compactMap { r in
            guard let id = r["id"] as? Int, let text = r["text"] as? String else { return nil }
            return TodoRow(id: id, text: text, owner: r["owner"] as? String, context: r["context"] as? String ?? "", createdAt: r["createdAt"] as? String ?? "", status: r["status"] as? String ?? "open")
        }
    }

    public func setTodo(_ id: Int, status: String) async {
        guard (try? await call(.setTodo(id, status: status)))?.type == "result", let i = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[i].status = status
    }

    public func startNoteTaking() {
        guard noteSession == nil else { return }
        let meeting = Meeting()
        noteSession = meeting
        meetingStore?.save(meeting)
    }

    /// Adds what was just heard to the transcript, saved at once.
    public func addNoteLine(_ line: String, speaker: Side = .me) async {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard noteSession != nil, !text.isEmpty else { return }
        noteSession?.add(MeetingLine(at: Date(), speaker: speaker, text: text))
        if let m = noteSession { meetingStore?.save(m) }
    }

    /// Ends the meeting, then has Jarvis write its note from the whole transcript (saved to memory as one note).
    public func stopNoteTaking() async {
        guard var meeting = noteSession else { return }
        noteSession = nil
        meeting.ended = Date()
        meetingStore?.save(meeting)
        await loadMeetings()
        if !meeting.lines.isEmpty { await writeNote(meeting.id) }
        await loadTodos()
    }

    public func loadMeetings() async { meetings = meetingStore?.list() ?? [] }

    /// Writes (or rewrites) a meeting's note. If the companion is away, the transcript stays and this can run later.
    public func writeNote(_ id: UUID) async {
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        notice = "Writing the meeting notes"
        let lines: [[String: Any]] = meeting.lines.map { ["at": ISO8601DateFormatter().string(from: $0.at), "speaker": $0.speaker.rawValue, "text": $0.text] }
        guard let e = try? await call(.meetingNote(id: id.uuidString, lines: lines, started: ISO8601DateFormatter().string(from: meeting.started))),
              e.type == "result", let note = e.body["note"] as? String else {
            notice = "Meeting saved. The notes will be written when Jarvis is reachable (Meetings, Write notes)."
            return
        }
        meeting.note = note
        meeting.title = e.body["title"] as? String
        meetingStore?.save(meeting)
        await loadMeetings()
        notice = "Meeting notes saved\(e.body["kept"] as? Bool == true ? " and added to memory" : "")."
    }

    /// Deletes the meeting and what Jarvis remembers of it.
    public func deleteMeeting(_ id: UUID) async {
        meetingStore?.delete(id)
        _ = try? await call(.forgetMeeting(id: id.uuidString))
        await loadMeetings()
    }

    public func loadNotes() async {
        guard let e = try? await call(.notes(contexts: Self.allSpaces.filter(spaces.contains))), let rows = e.body["notes"] as? [[String: Any]] else { return }
        notes = rows.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            return NoteRow(id: id, summary: r["summary"] as? String ?? "", context: r["context"] as? String ?? "", createdAt: r["createdAt"] as? String ?? "",
                           happened: r["happened"] as? String ?? "", replaced: r["replaced"] as? Bool ?? false)
        }
    }

    /// Reads a file you picked and hands its text to the companion, which saves it to memory in the background.
    /// Several files at once (exports from other assistants): the companion imports them one after another.
    public func importFiles(_ urls: [URL]) async {
        for url in urls { await importFile(url) }
        if urls.count > 1, importProgress == nil { notice = "Importing \(urls.count) files, one after another." }
    }

    public func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { notice = "Could not read that file. Markdown and plain text work."; return }
        do {
            let e = try await call(.importText(name: url.lastPathComponent, text: text))
            notice = e.type == "result"
                ? ((e.body["chunks"] as? Int ?? 0) == 0 ? "\(url.lastPathComponent) is already in memory." : "Importing \(url.lastPathComponent): \(e.body["chunks"] as? Int ?? 0) parts.")
                : e.body["message"] as? String ?? "Could not import that file."
        } catch { notice = "The companion is offline, so the file was not imported." }
    }

    @Published public private(set) var tasks: [BackgroundTask] = []

    /// Follows the background tasks for as long as the companion streams them: shows them, puts each report in the chat
    /// once, and passes on what they need your yes for.
    public func watchTasksOnce() async {
        do {
            for try await e in api.send(.watchTasks, id: UUID().uuidString) {
                if e.type == "approval" { addApproval(e.body, background: true); continue }
                // A scheduled job reports as a background task; a plain reminder is shown and announced.
                if e.type == "reminder", let rid = e.body["reminderId"] as? Int, let text = e.body["text"] as? String {
                    if e.body["run"] as? Bool != true {
                        chat.append(ChatTurn(role: "assistant", text: "**Reminder:** \(text)")); persist()
                        onReminder?(rid, text)
                    }
                    continue
                }
                guard e.type == "task", let id = e.body["id"] as? String else { continue }
                let task = BackgroundTask(id: id, goal: e.body["goal"] as? String ?? "", status: e.body["status"] as? String ?? "running", steps: e.body["steps"] as? Int ?? 0)
                if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i] = task } else { tasks.append(task) }
                let finished = tasks.filter { $0.status != "running" }
                if finished.count > 20 { tasks.removeAll { t in finished.prefix(finished.count - 20).contains { $0.id == t.id } } }
                guard task.status != "running", !chat.contains(where: { $0.taskId == id }) else { continue }
                let result = e.body["result"] as? String ?? ""
                let text = switch task.status {
                    case "done": "**Finished in the background:** \(task.goal)\n\n\(result)"
                    case "cancelled": "**Stopped the background task:** \(task.goal)"
                    default: "**The background task did not finish:** \(task.goal)\n\n\(result)"
                }
                var turn = ChatTurn(role: "assistant", text: text)
                turn.taskId = id
                chat.append(turn)
                persist()
            }
        } catch {}
    }

    public func watchTasks() async {
        while !Task.isCancelled {
            await watchTasksOnce()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    public func cancelTask(_ id: String) async { _ = try? await call(.cancelTask(id: id)) }

    public func snoozeReminder(_ id: Int, minutes: Int = 10) async { _ = try? await call(.reminder(id: id, action: "snooze", minutes: minutes)) }

    /// Follows the browser for as long as the companion streams it (one connection).
    public func watchBrowserOnce() async {
        do {
            for try await e in api.send(.watchBrowser, id: UUID().uuidString) where e.type == "browser" {
                browser.state = e.body["state"] as? String ?? "idle"
                browser.reason = e.body["reason"] as? String ?? (browser.state == "needsUser" ? browser.reason : "")
                if let url = e.body["url"] as? String { browser.url = url }
                if let f = (e.body["frame"] as? String).flatMap({ Data(base64Encoded: $0) }) { browser.frame = f }
            }
        } catch {}
        browser = BrowserView() // the companion went away: nothing is waiting on you any more
    }

    /// Keeps following the browser, reconnecting when the companion restarts.
    public func watchBrowser() async {
        while !Task.isCancelled {
            await watchBrowserOnce()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    // Your input in Jarvis's browser, only while it is your turn (the companion checks this too).
    private func browserSend(_ input: [String: Any]) async {
        guard browser.state == "needsUser" else { return }
        _ = try? await call(.browserInput(input))
    }
    public func browserClick(x: Double, y: Double) async { await browserSend(["kind": "click", "x": x, "y": y]) }
    public func browserType(_ text: String) async { await browserSend(["kind": "type", "text": text]) }
    public func browserKey(_ key: String) async { await browserSend(["kind": "key", "key": key]) }
    public func browserScroll(_ dy: Double) async { await browserSend(["kind": "scroll", "dy": dy]) }
    /// Hands control back to Jarvis.
    @discardableResult public func browserResume(_ note: String = "") async -> Bool { (try? await call(.browserResume(note: note)))?.type == "result" }

    /// Fetches an image link through the companion (the app has no internet). Unknown links wait for a click.
    public func loadImage(_ url: String, clicked: Bool) async -> ImageLoad {
        guard let e = try? await call(.image(url: url, clicked: clicked)), e.type == "result" else { return .blocked("The companion is offline.") }
        switch e.body["status"] as? String {
        case "ok": return (e.body["data"] as? String).flatMap { Data(base64Encoded: $0) }.map { .ready($0) } ?? .blocked("Could not read the image.")
        case "ask": return .ask
        default: return .blocked(e.body["reason"] as? String ?? "Not loaded.")
        }
    }

    public func answerApproval(_ ok: Bool) async {
        guard let pending = approvals.first else { return }
        await answerApproval(id: pending.id, ok: ok)
    }

    /// Answers exactly the request that was shown; if it is no longer waiting, nothing happens.
    public func answerApproval(id: String, ok: Bool) async {
        guard approvals.contains(where: { $0.id == id }) else { return }
        approvals.removeAll { $0.id == id }
        _ = try? await call(.approve(approvalId: id, ok: ok))
    }

    public func loadSetup() async {
        guard let e = try? await call(.setup), let rows = e.body["keys"] as? [[String: Any]] else { return }
        setupKeys = rows.map { SetupKey(name: $0["name"] as? String ?? "", purpose: $0["purpose"] as? String ?? "", required: $0["required"] as? Bool ?? false, set: $0["set"] as? Bool ?? false) }
    }

    /// Sends a key to the companion, which checks it, keeps it in the Keychain and restarts to use it. Empty removes it.
    public func saveKey(_ name: String, value: String) async -> Bool {
        guard let e = try? await call(.setKey(name: name, value: value)) else { notice = "The companion is offline."; return false }
        if e.type != "result" { notice = e.body["message"] as? String ?? "Could not save that key."; return false }
        notice = value.isEmpty ? "Key removed." : "Key saved in the Keychain. Jarvis's helper restarts to use it (about 10 seconds)."
        return true
    }

    public func loadConnectors() async {
        guard let e = try? await call(.connectors), let rows = e.body["servers"] as? [[String: Any]] else { return }
        connectors = rows.map { ($0["name"] as? String ?? "", $0["tools"] as? Int ?? 0, $0["url"] as? String ?? "", $0["needsSignIn"] as? Bool ?? false) }
    }

    public func loadApps() async {
        guard let e = try? await call(.apps), e.type == "result" else { return }
        apps = (e.body["apps"] as? [[String: Any]] ?? []).map { a in
            AppRow(slug: a["slug"] as? String ?? "", name: a["name"] as? String ?? "", group: a["group"] as? String ?? "", about: a["about"] as? String ?? "",
                   connected: a["connected"] as? Bool ?? false,
                   accounts: (a["accounts"] as? [[String: Any]] ?? []).map { AppAccount(id: $0["id"] as? String ?? "", status: $0["status"] as? String ?? "", alias: $0["alias"] as? String ?? "", who: $0["who"] as? String ?? "") })
        }
    }

    /// Opens Composio's sign-in for this app; a label keeps several accounts apart (work, personal).
    public func connect(app: String, alias: String = "") async {
        guard let e = try? await call(.connectApp(toolkit: app, alias: alias)) else { notice = "The companion is offline."; return }
        guard e.type == "result", let link = e.body["url"] as? String, let url = URL(string: link), url.scheme == "https" else {
            notice = e.body["message"] as? String ?? "Could not start connecting that app."; return
        }
        openURL?(url)
        notice = "Finish signing in in your browser, then come back here."
    }

    public func rename(app: String, account: String, to alias: String) async {
        _ = try? await call(.renameApp(toolkit: app, accountId: account, alias: alias))
        await loadApps()
    }

    public func remove(app: String, account: String) async {
        _ = try? await call(.removeApp(toolkit: app, accountId: account))
        await loadApps()
    }

    /// Adds your own MCP server. The header value is stored in the Keychain by the companion.
    public func addServer(name: String, url: String, headerName: String, headerValue: String) async -> Bool {
        guard let e = try? await call(.addMcp(name: name, url: url, headerName: headerName, headerValue: headerValue)) else { notice = "The companion is offline."; return false }
        if e.type != "result" { notice = e.body["message"] as? String ?? "Could not add that server."; return false }
        await loadConnectors()
        return true
    }

    /// Opens an MCP server's own login page in your browser; the companion takes it from there.
    public func signIn(server name: String) async {
        guard let e = try? await call(.mcpSignIn(name: name)), e.type == "result", let link = e.body["url"] as? String, let url = URL(string: link), url.scheme == "https" else {
            notice = "Could not start the sign-in."; return
        }
        openURL?(url)
        notice = "Finish signing in in your browser, then come back here."
    }

    public func removeServer(_ name: String) async {
        _ = try? await call(.removeMcp(name: name))
        await loadConnectors()
    }

    /// Brings back a note that was marked replaced (by a newer note or the nightly clean-up).
    public func restore(segmentId: Int) async {
        guard (try? await call(.restore(segmentId: segmentId)))?.type == "result" else { return }
        await loadNotes()
    }

    public func forget(segmentId: Int) async {
        guard (try? await call(.forget(segmentId: segmentId)))?.type == "result" else { return }
        notes.removeAll { $0.id == segmentId }
        await refreshStatus(); await loadGraph()
    }
}
