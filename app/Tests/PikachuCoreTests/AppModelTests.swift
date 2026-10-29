import XCTest
@testable import PikachuCore

private struct Fake: CompanionAPI {
    /// Streams of this request kind stay open after their events, like a live companion connection.
    var holdOpen: (@Sendable (Request) -> Bool)? = nil
    var script: @Sendable (Request) -> [Result<Event, Error>]
    func send(_ request: Request, id: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { c in
            for step in script(request) {
                switch step { case .success(let e): c.yield(e); case .failure(let err): c.finish(throwing: err); return }
            }
            if holdOpen?(request) != true { c.finish() }
        }
    }
}

private func event(_ type: String, _ extra: JSON = [:]) -> Event {
    var body: JSON = ["id": "1", "type": type]; body.merge(extra) { $1 }
    return Event(line: try! JSONSerialization.data(withJSONObject: body))!
}

@MainActor
final class AppModelTests: XCTestCase {
    func testAskAppendsSentencesThenCitations() async {
        let m = AppModel(api: Fake { _ in [.success(event("sentence", ["text": "Friday."])), .success(event("sentence", ["text": "It is Zentro."])),
                                           .success(event("result", ["citations": ["c1"], "model": "claude-haiku-5-5", "ms": ["total": 900]]))] })
        m.question = "When?"
        await m.ask()
        XCTAssertEqual(m.chat.map(\.role), ["user", "assistant"])
        XCTAssertEqual(m.chat[1].text, "Friday. It is Zentro.") // no tokens: falls back to the spoken sentences
        XCTAssertEqual(m.chat[1].citations, ["c1"])
        XCTAssertEqual(m.chat[1].meta, "HAIKU-5-5  /  900 MS")
        XCTAssertEqual(m.question, "")
        XCTAssertFalse(m.asking)
    }

    func testTokensBuildTheLiveAnswerText() async {
        let m = AppModel(api: Fake { _ in [.success(event("token", ["text": "Fri"])), .success(event("token", ["text": "day [1]."])), .success(event("sentence", ["text": "Friday."])), .success(event("result", ["citations": ["c1"]]))] })
        m.question = "When?"
        await m.ask()
        XCTAssertEqual(m.chat.last?.text, "Friday [1].")
    }

    func testOfflineShowsAPoliteNoticeAndMarksDisconnected() async {
        let m = AppModel(api: Fake { _ in [.failure(CompanionError.offline)] })
        m.question = "When?"
        await m.ask()
        XCTAssertFalse(m.connected)
        XCTAssertTrue(m.chat.last?.text.contains("offline") ?? false)
        XCTAssertTrue(m.chat.last?.failed ?? false)
    }

    func testPausedErrorIsShownAsTheNotice() async {
        let m = AppModel(api: Fake { _ in [.success(event("error", ["code": "paused", "message": "Cloud processing is paused. Nothing was sent."]))] })
        m.question = "When?"
        await m.ask()
        XCTAssertEqual(m.chat.last?.text, "Cloud processing is paused. Nothing was sent.")
    }

    func testPersonalIsOffByDefaultAndAskSendsOnlyEnabledSpaces() async {
        var sent: [String] = []
        let box = Box()
        let m = AppModel(api: Fake { req in if case let .ask(_, contexts, _, _, _, _) = req { box.contexts = contexts }; return [.success(event("result"))] })
        XCTAssertFalse(m.spaces.contains("personal"))
        m.question = "x"; await m.ask()
        sent = box.contexts
        XCTAssertEqual(sent, ["company", "professional"])
        await m.toggle(space: "personal"); m.question = "x"; await m.ask()
        XCTAssertEqual(box.contexts, ["company", "professional", "personal"])
    }

    func testToolStepsBehindAnAnswerGoBackWithTheNextQuestion() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .ask(_, _, history, _, _, _) = req { box.history = history }
            return [.success(event("token", ["text": "Quote ready."])), .success(event("result", ["work": "[{\"tool\":\"get_quote\"}]"]))]
        })
        m.question = "quote a poster"; await m.ask()
        m.question = "yes"; await m.ask()
        XCTAssertEqual(box.history.last?.filter { $0.key != "id" }, ["role": "assistant", "content": "Quote ready.", "work": "[{\"tool\":\"get_quote\"}]"])
    }

    func testWhileJarvisWaitsOnYouTheChatReplyGoesToItAndIsNotSaved() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .browserResume(note) = req { box.history = [["note": note]] }
            return [.success(event("result"))]
        })
        m.browser.state = "needsUser"
        m.question = "user tom, password hunter2"; await m.ask()
        XCTAssertEqual(box.history, [["note": "user tom, password hunter2"]])
        XCTAssertTrue(m.chat.isEmpty, "login details never land in the saved chat")
        XCTAssertEqual(m.question, "")
    }

    func testTheRunningSummaryGoesWithEachQuestionAndFoldedTurnsAreNotResent() async {
        final class Seen: @unchecked Sendable { var asks: [(history: [[String: String]], summary: String)] = [] }
        let seen = Seen()
        let m = AppModel(api: Fake { req in
            guard case let .ask(_, _, history, _, summary, _) = req else { return [.success(event("result"))] }
            seen.asks.append((history, summary))
            // On the second question the companion folds everything sent so far into a summary.
            let fold: JSON = seen.asks.count == 2 ? ["summary": "Planning the Orbit launch.", "foldedThrough": history.last?["id"] ?? ""] : [:]
            return [.success(event("token", ["text": "Ok."])), .success(event("result", fold))]
        })
        for q in ["one", "two", "three"] { m.question = q; await m.ask() }
        XCTAssertEqual(seen.asks[1].history.map { $0["content"] }, ["one", "Ok."])
        XCTAssertNotNil(seen.asks[1].history.first?["id"], "turns carry their id so the companion can say how far it folded")
        XCTAssertEqual(seen.asks[2].summary, "Planning the Orbit launch.")
        XCTAssertEqual(seen.asks[2].history.map { $0["content"] }, ["two", "Ok."], "folded turns are not sent again")
    }

    func testLoginDetailsYouSentAreScrubbedFromTheChatEvenWhenAnAnswerIsCutShort() async {
        let m = AppModel(api: Fake { _ in [.success(event("result"))] })
        m.browser.state = "needsUser"
        m.question = "user tom, password Hunter2!x"; await m.ask()
        m.browser.state = "idle"
        XCTAssertEqual(m.scrubbed("Typed Hunter2!x and logged in as tom, password safe"), "Typed [sent by the user] and logged in as tom, password safe",
                       "details you sent, as whole words; everyday words and filler like password stay")
        m.browser.state = "needsUser"
        m.question = "my password is correcthorse"; await m.ask()
        XCTAssertEqual(m.scrubbed("used correcthorse to log in"), "used [sent by the user] to log in", "lowercase secrets too")
    }

    func testApprovalsQueueAndANewQuestionNeverDropsABackgroundOne() async {
        let m = AppModel(api: Fake { req in
            if case .watchTasks = req { return [.success(event("approval", ["approvalId": "bg", "action": "Background task: send"]))] }
            if case .ask = req { return [.success(event("approval", ["approvalId": "fg", "action": "Send email"])), .success(event("result"))] }
            return [.success(event("result"))]
        })
        await m.watchTasksOnce()
        m.question = "send it"; await m.ask()
        XCTAssertEqual(m.approvals.map(\.id), ["bg", "fg"], "both wait, one after the other")
        m.question = "something else"; await m.ask()
        XCTAssertEqual(m.approvals.map(\.id), ["bg", "fg"].filter { $0 == "bg" } + ["fg"], "a new question replaces only the chat's own request")
        await m.answerApproval(true)
        XCTAssertEqual(m.approvals.map(\.id), ["fg"])
        await m.answerApproval(id: "gone", ok: true)
        XCTAssertEqual(m.approvals.map(\.id), ["fg"], "a yes only ever goes to the exact request that was shown")
    }

    func testADueReminderIsShownAndAnnouncedAndCanBeSnoozed() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case .watchTasks = req { return [.success(event("reminder", ["reminderId": 4, "text": "Drink water", "run": false])),
                                                .success(event("reminder", ["reminderId": 5, "text": "Summarize email", "run": true]))] }
            if case let .reminder(id, action, minutes) = req { box.contexts = ["\(id)", action, "\(minutes)"] }
            return [.success(event("result", ["ok": true]))]
        })
        var announced: [String] = []
        m.onReminder = { _, text in announced.append(text) }
        await m.watchTasksOnce()
        XCTAssertEqual(announced, ["Drink water"], "a scheduled job reports as a background task instead")
        XCTAssertEqual(m.chat.last?.text, "**Reminder:** Drink water")
        await m.snoozeReminder(4)
        XCTAssertEqual(box.contexts, ["4", "snooze", "10"])
    }

    func testJarvisCanSwitchNoteTakingOnAndOff() async {
        let m = AppModel(api: Fake { _ in [.success(event("control", ["action": "startNotes"])), .success(event("result"))] })
        var actions: [String] = []
        m.onControl = { actions.append($0) }
        m.question = "take notes for this meeting"; await m.ask()
        XCTAssertEqual(actions, ["startNotes"])
    }

    func testWhenTheBrowserStreamEndsItsStateIsReset() async {
        let m = AppModel(api: Fake { req in
            if case .watchBrowser = req { return [.success(event("browser", ["state": "needsUser", "reason": "Log in"]))] }
            return [.success(event("result"))]
        })
        await m.watchBrowserOnce()
        XCTAssertFalse(m.waitingForYou, "a companion that went away is not waiting on you")
    }

    func testAttachmentsComeBackWhenTheQuestionFails() async {
        let m = AppModel(api: Fake { _ in [.failure(CompanionError.offline)] })
        m.attached = [Attached(name: "a.pdf", data: Data("x".utf8))]
        m.question = "read this"; await m.ask()
        XCTAssertEqual(m.attached.map(\.name), ["a.pdf"])
    }

    func testFollowUpsCarryTheConversationButNotFailedTurns() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .ask(_, _, history, _, _, _) = req { box.history = history }
            return [.success(event("token", ["text": "Answer."])), .success(event("result"))]
        })
        m.question = "first"; await m.ask()
        m.question = "second"; await m.ask()
        XCTAssertEqual(box.history.map { $0.filter { $0.key != "id" } }, [["role": "user", "content": "first"], ["role": "assistant", "content": "Answer."]])
        XCTAssertEqual(m.chat.count, 4)
    }

    func testOnlySpokenQuestionsAreSpokenBack() async {
        let box = Box()
        let m = AppModel(api: Fake { _ in [.success(event("sentence", ["text": "Hi."])), .success(event("result"))] })
        m.onSentence = { _, _ in box.calls += 1 }
        m.question = "typed"; await m.ask()
        XCTAssertEqual(box.calls, 0)
        m.question = "spoken"; await m.ask(speak: true)
        XCTAssertEqual(box.calls, 1)
    }

    func testBlankQuestionSendsNothing() async {
        let box = Box()
        let m = AppModel(api: Fake { _ in box.calls += 1; return [] })
        m.question = "   "; await m.ask()
        XCTAssertEqual(box.calls, 0)
    }

    func testRememberSendsTheNoteAndSaysWhereItWent() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .ingest(text, _) = req { box.history = [["text": text]] }
            return [.success(event("result", ["kept": true, "context": "company"]))]
        })
        await m.remember("  Ship the Orbit API on Friday.  ")
        XCTAssertEqual(box.history, [["text": "Ship the Orbit API on Friday."]])
        XCTAssertEqual(m.notice, "Note saved to company.")
    }

    func testRememberSaysWhenANoteIsNotKept() async {
        let m = AppModel(api: Fake { _ in [.success(event("result", ["kept": false]))] })
        await m.remember("testing one two")
        XCTAssertEqual(m.notice, "Not saved: nothing worth keeping, or it looked private.")
    }

    func testAnAnswerSaysWhenTheChatTaughtItSomething() async {
        let m = AppModel(api: Fake { _ in [.success(event("result", ["saved": ["context": "company", "replaced": 1]]))] })
        m.question = "No, the Orbit launch moved to Monday"; await m.ask()
        XCTAssertEqual(m.chat.last?.learned, "Saved to company, replaced 1 older note")
    }

    func testRememberMentionsReplacedNotes() async {
        let m = AppModel(api: Fake { _ in [.success(event("result", ["kept": true, "context": "company", "replaced": 2]))] })
        await m.remember("Orbit launch moved to Monday.")
        XCTAssertEqual(m.notice, "Note saved to company, replaced 2 older notes.")
    }

    func testALearnedSpellingIsShownAndUsedForSpeech() async {
        let m = AppModel(api: Fake { req in
            if case .status = req { return [.success(event("result", ["spellings": ["zentra": "Zentro"]]))] }
            return [.success(event("result", ["spelling": ["heard": "zentra", "correct": "Zentro"]]))]
        })
        m.question = "It is Zentro, not zentra"; await m.ask()
        XCTAssertEqual(m.chat.last?.learned, "Learned: zentra is Zentro")
        await m.refreshStatus()
        XCTAssertEqual(m.spellings, ["zentra": "Zentro"])
    }

    func testTraceStepsAreCollectedForTheLiveView() async {
        let m = AppModel(api: Fake { _ in [
            .success(event("trace", ["stage": "memory", "nodes": [4, 2], "notes": 1])),
            .success(event("trace", ["stage": "web", "queries": ["London weather"]])),
            .success(event("trace", ["stage": "sources", "sources": [["title": "Weather", "host": "w.example"]]])),
            .success(event("trace", ["stage": "answer", "model": "claude-sonnet-5-5"])),
            .success(event("result")),
        ] })
        m.question = "Will it rain?"; await m.ask()
        XCTAssertEqual(m.trace.stages, ["memory", "web", "sources", "answer"])
        XCTAssertEqual(m.trace.nodes, [4, 2])
        XCTAssertEqual(m.trace.queries, ["London weather"])
        XCTAssertEqual(m.trace.sources, ["w.example"])
        XCTAssertEqual(m.trace.model, "SONNET-5-5")
        XCTAssertTrue(m.trace.done)
    }

    func testRatingAnAnswerSendsItWithItsQuestionAndMarksTheTurn() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .feedback(rating, question, answer, model) = req { box.history = [["rating": rating, "q": question, "a": answer, "m": model]] }
            if case .ask = req { return [.success(event("token", ["text": "Friday."])), .success(event("result", ["model": "claude-haiku-5-5"]))] }
            return [.success(event("result"))]
        })
        m.question = "When is the Orbit launch?"; await m.ask()
        let answer = m.chat.last!
        await m.rate(answer.id, up: false)
        XCTAssertEqual(box.history, [["rating": "down", "q": "When is the Orbit launch?", "a": "Friday.", "m": "claude-haiku-5-5"]])
        XCTAssertEqual(m.chat.last?.rating, "down")
    }

    func testPersonalNeedsTouchIDToTurnOnButNotOff() async {
        let m = AppModel(api: Fake { _ in [] })
        var allow = false, asked = 0
        m.authorize = { _ in asked += 1; return allow }
        await m.toggle(space: "personal")
        XCTAssertFalse(m.spaces.contains("personal"), "refused")
        allow = true
        await m.toggle(space: "personal")
        XCTAssertTrue(m.spaces.contains("personal"))
        await m.toggle(space: "personal")
        XCTAssertFalse(m.spaces.contains("personal"))
        await m.toggle(space: "company")
        XCTAssertEqual(asked, 2, "only turning personal on asks")
    }

    func testSpokenAnswersAppearSentenceBySentenceAsTheyAreSaidAndAskForShortReplies() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .ask(_, _, _, voice, _, _) = req { box.calls = voice ? 1 : 0 }
            return [.success(event("token", ["text": "Friday. It is Zentro."])), .success(event("sentence", ["text": "Friday."])),
                    .success(event("sentence", ["text": "It is Zentro."])), .success(event("result"))]
        })
        var heard: [(String, UUID)] = []
        m.onSentence = { text, id in heard.append((text, id)) }
        m.question = "When?"; await m.ask(speak: true)
        XCTAssertEqual(box.calls, 1, "voice flag sent")
        XCTAssertEqual(m.chat.last?.text, "", "nothing shown until it is spoken")
        XCTAssertEqual(heard.map(\.0), ["Friday.", "It is Zentro."])
        m.reveal(heard[0].1, heard[0].0)
        XCTAssertEqual(m.chat.last?.text, "Friday.")
        m.reveal(heard[1].1, heard[1].0)
        XCTAssertEqual(m.chat.last?.text, "Friday. It is Zentro.")
    }

    func testASpokenAnswerIsShownOnceEvenWhenTheWholeAnswerArrivesBeforeItIsSaid() async {
        let m = AppModel(api: Fake { _ in
            [.success(event("sentence", ["text": "Friday."])), .success(event("sentence", ["text": "It is Zentro."])),
             .success(event("result", ["answer": "Friday. It is Zentro."]))]
        })
        var heard: [(String, UUID)] = []
        m.onSentence = { text, id in heard.append((text, id)) }
        m.question = "When?"; await m.ask(speak: true)
        XCTAssertEqual(m.chat.last?.text, "Friday. It is Zentro.", "shown once complete, even if the app closes before it is all said")
        for (text, id) in heard { m.reveal(id, text) } // spoken after the answer was complete
        XCTAssertEqual(m.chat.last?.text, "Friday. It is Zentro.")
    }

    func testInterruptingStopsTheAnswerAndAnUnansweredQuestionCanBeTakenBack() async {
        let m = AppModel(api: Fake { _ in [.success(event("trace", ["stage": "memory", "nodes": [], "notes": 0]))] + (0..<50).map { _ in .success(event("sentence", ["text": "More."])) } + [.success(event("result"))] })
        var said = 0
        m.onSentence = { _, _ in said += 1; if said == 1 { m.interrupt() } }
        m.question = "Tell me everything"; await m.ask(speak: true)
        XCTAssertEqual(said, 1, "no sentence after the interruption")
        XCTAssertFalse(m.asking)
        XCTAssertEqual(m.retractUnanswered(), "Tell me everything", "interrupted before a word was said")
        XCTAssertTrue(m.chat.isEmpty)
        XCTAssertNil(m.retractUnanswered(), "nothing left to take back")
    }

    func testLearnedInstructionsAreListedAndCanBeRemoved() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .setInstructions(list) = req { box.contexts = list; return [.success(event("result"))] }
            return [.success(event("result", ["instructions": ["Always keep it short.", "Never use emojis."]]))]
        })
        await m.refreshStatus()
        XCTAssertEqual(m.instructions, ["Always keep it short.", "Never use emojis."])
        await m.removeInstruction("Always keep it short.")
        XCTAssertEqual(box.contexts, ["Never use emojis."])
        XCTAssertEqual(m.instructions, ["Never use emojis."])
    }

    func testInterruptFreesTheAppAtOnceEvenIfTheCompanionGoesQuiet() async {
        let m = AppModel(api: Hang())
        let started = Date()
        Task { try? await Task.sleep(for: .milliseconds(150)); m.interrupt() }
        m.question = "Tell me everything"; await m.ask(speak: true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertFalse(m.asking)
    }

    func testOnlyAnInterruptedEmptyAnswerCanBeTakenBackAndStopSettlesIt() async {
        let m = AppModel(api: Fake { _ in [.success(event("result"))] })
        m.question = "Q1"; await m.ask(speak: true)          // voice failed to play: empty, not interrupted
        XCTAssertNil(m.retractUnanswered(), "a silent answer is not an interruption")
        let h = AppModel(api: Hang())
        Task { try? await Task.sleep(for: .milliseconds(100)); h.interrupt() }
        h.question = "Q2"; await h.ask(speak: true)
        h.settleInterrupted()                                  // you said "stop"
        XCTAssertNil(h.retractUnanswered())
        XCTAssertEqual(h.chat.last?.text, "(stopped)")
    }

    func testNotesListUsesTheOpenSpacesAndForgettingRemovesTheRow() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            switch req {
            case let .notes(contexts): box.contexts = contexts
                return [.success(event("result", ["notes": [["id": 7, "summary": "Gym at six", "context": "personal", "createdAt": "2026-10-22 07:00:00", "happened": "2026-10", "replaced": false],
                                                            ["id": 3, "summary": "Gym at seven", "context": "personal", "createdAt": "2026-10-20 07:00:00", "replaced": true]]]))]
            default: return [.success(event("result"))]
            }
        })
        await m.loadNotes()
        XCTAssertEqual(box.contexts, ["company", "professional"])
        XCTAssertEqual(m.notes.map(\.summary), ["Gym at six", "Gym at seven"])
        XCTAssertEqual(m.notes.map(\.replaced), [false, true])
        XCTAssertEqual(m.notes.map(\.happened), ["2026-10", ""])
        await m.forget(segmentId: 3)
        XCTAssertEqual(m.notes.map(\.id), [7])
    }

    func testTodosLoadForTheOpenSpacesAndCanBeTicked() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            switch req {
            case let .todos(contexts): box.contexts = contexts
                return [.success(event("result", ["todos": [["id": 4, "text": "Send the deck", "owner": "Ravi", "status": "open", "context": "company", "createdAt": "2026-10-22 07:00:00"]]]))]
            case let .setTodo(id, status): box.history = [["id": "\(id)", "status": status]]; return [.success(event("result"))]
            default: return [.success(event("result"))]
            }
        })
        await m.loadTodos()
        XCTAssertEqual(box.contexts, ["company", "professional"])
        XCTAssertEqual(m.todos.first?.text, "Send the deck")
        XCTAssertEqual(m.openTodos, 1)
        await m.setTodo(4, status: "done")
        XCTAssertEqual(box.history, [["id": "4", "status": "done"]])
        XCTAssertEqual(m.todos.first?.status, "done")
        XCTAssertEqual(m.openTodos, 0)
    }

    func testAMeetingKeepsItsWholeTranscriptAndGetsANoteWhenStopped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(directory: dir)
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case .ingest = req { box.calls += 1 }
            if case let .meetingNote(_, lines, _) = req {
                box.history = lines.map { ["speaker": $0["speaker"] as? String ?? "", "text": $0["text"] as? String ?? ""] }
                return [.success(event("result", ["title": "Atlas launch sync", "note": "## Summary\nAtlas moves to Monday.", "kept": true]))]
            }
            return [.success(event("result"))]
        }, meetings: store)
        m.startNoteTaking()
        await m.addNoteLine("Asha says the Atlas launch moves to Monday.", speaker: .them)
        await m.addNoteLine("Okay, I'll update the plan.", speaker: .me)
        // Saved as it goes: a crash mid-meeting loses nothing.
        XCTAssertEqual(store.list().first?.lines.count, 2)
        XCTAssertEqual(box.calls, 0, "nothing goes to memory in pieces during the meeting")
        await m.stopNoteTaking()
        XCTAssertNil(m.noteSession)
        XCTAssertEqual(box.history, [["speaker": "Them", "text": "Asha says the Atlas launch moves to Monday."], ["speaker": "Me", "text": "Okay, I'll update the plan."]])
        let saved = try XCTUnwrap(m.meetings.first)
        XCTAssertEqual(saved.title, "Atlas launch sync")
        XCTAssertEqual(saved.note, "## Summary\nAtlas moves to Monday.")
        XCTAssertNotNil(saved.ended)
        XCTAssertEqual(store.list().first?.note, saved.note, "the note is kept with its transcript")
    }

    func testDeletingAMeetingAlsoForgetsWhatJarvisRemembersOfIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(directory: dir)
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .forgetMeeting(id) = req { box.history = [["id": id]] }
            return [.success(event("result"))]
        }, meetings: store)
        m.startNoteTaking()
        await m.addNoteLine("Budget is approved.", speaker: .them)
        let id = try XCTUnwrap(store.list().first?.id)
        await m.deleteMeeting(id)
        XCTAssertEqual(box.history, [["id": id.uuidString]])
        XCTAssertTrue(store.list().isEmpty)
    }

    func testAMeetingCutOffByACrashIsClosedAtItsLastLineOnTheNextLaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(directory: dir)
        var cut = Meeting(started: Date(timeIntervalSince1970: 1_000))
        let last = Date(timeIntervalSince1970: 1_600)
        cut.lines = [MeetingLine(at: last, speaker: .them, text: "And that's the plan.")]
        store.save(cut) // never ended: the app quit mid-meeting
        let m = AppModel(api: Fake { _ in [] }, meetings: store)
        XCTAssertEqual(try XCTUnwrap(m.meetings.first).ended, last)
        XCTAssertEqual(store.list().first?.ended, last)
    }

    func testAMeetingStoppedWhileOfflineKeepsItsTranscriptAndTheNoteCanBeWrittenLater() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(directory: dir)
        let offline = AppModel(api: Fake { _ in [.failure(CompanionError.offline)] }, meetings: store)
        offline.startNoteTaking()
        await offline.addNoteLine("Ship on Friday.", speaker: .them)
        await offline.stopNoteTaking()
        let pending = try XCTUnwrap(store.list().first)
        XCTAssertNil(pending.note)
        XCTAssertEqual(pending.lines.map(\.text), ["Ship on Friday."])
        let back = AppModel(api: Fake { _ in [.success(event("result", ["title": "Ship date", "note": "Ship on Friday."]))] }, meetings: store)
        await back.loadMeetings()
        await back.writeNote(pending.id)
        XCTAssertEqual(store.list().first?.title, "Ship date")
    }

    func testImportingAFileSendsItsTextAndShowsProgress() async throws {
        let box = Box()
        let m = AppModel(api: Fake { req in
            if case let .importText(name, text) = req { box.history = [["name": name, "text": text]]; return [.success(event("result", ["chunks": 3]))] }
            return [.success(event("result", ["importing": ["name": "team.md", "done": 1, "total": 3]]))]
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("team.md")
        try "# Atlas\nAsha leads Atlas.".write(to: url, atomically: true, encoding: .utf8)
        await m.importFile(url)
        XCTAssertEqual(box.history, [["name": "team.md", "text": "# Atlas\nAsha leads Atlas."]])
        XCTAssertEqual(m.notice, "Importing team.md: 3 parts.")
        await m.refreshStatus()
        XCTAssertEqual(m.importProgress, "Importing team.md: 1 of 3")
    }

    func testAnApprovalRequestIsShownAndAnsweredAndToolStepsShowInTheTrace() async {
        let box = Box()
        let jpeg = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        let m = AppModel(api: Fake { req in
            if case let .approve(approvalId, ok) = req { box.history = [["id": approvalId, "ok": "\(ok)"]]; return [.success(event("result"))] }
            return [.success(event("trace", ["stage": "tool", "name": "browser_open", "detail": "shop.example"])),
                    .success(event("screenshot", ["jpeg": jpeg])),
                    .success(event("approval", ["approvalId": "ap-1", "action": "Click \"Place order\" on shop.example"])),
                    .success(event("result"))]
        })
        m.question = "Order more coffee"; await m.ask()
        XCTAssertEqual(m.pendingApproval?.action, "Click \"Place order\" on shop.example")
        XCTAssertEqual(m.trace.tools.map(\.name), ["browser_open"])
        XCTAssertEqual(m.browserShot, Data([0xFF, 0xD8, 0xFF]))
        await m.answerApproval(false)
        XCTAssertEqual(box.history, [["id": "ap-1", "ok": "false"]])
        XCTAssertNil(m.pendingApproval)
    }

    func testConnectedServersAreListedAndOwnServersCanBeAddedAndRemoved() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            switch req {
            case .connectors: return [.success(event("result", ["servers": [["name": "composio", "tools": 5, "url": "https://connect.composio.dev/mcp"]]]))]
            case let .addMcp(name, url, header, value): box.history = [["name": name, "url": url, "header": header, "value": value]]; return [.success(event("result"))]
            case let .removeMcp(name): box.contexts = [name]; return [.success(event("result"))]
            default: return [.success(event("result"))]
            }
        })
        await m.loadConnectors()
        XCTAssertEqual(m.connectors.map(\.name), ["composio"])
        XCTAssertEqual(m.connectors.first?.tools, 5)
        let ok = await m.addServer(name: "tickets", url: "https://mcp.example", headerName: "Authorization", headerValue: "Bearer x")
        XCTAssertTrue(ok)
        XCTAssertEqual(box.history.first?["header"], "Authorization")
        await m.removeServer("tickets")
        XCTAssertEqual(box.contexts, ["tickets"])
    }

    func testSetupShowsWhichKeysAreMissingAndSavesOneThroughTheCompanion() async {
        let box = Box()
        let m = AppModel(api: Fake { req in
            switch req {
            case .setup: return [.success(event("result", ["keys": [["name": "ANTHROPIC_API_KEY", "required": true, "purpose": "Answers", "set": false],
                                                                     ["name": "TINYFISH_API_KEY", "required": false, "purpose": "Web search", "set": true]]]))]
            case let .setKey(name, value):
                box.history = [["name": name, "value": value]]
                return [.success(value == "bad" ? event("error", ["message": "Anthropic rejected that key."]) : event("result", ["ok": true]))]
            default: return [.success(event("result"))]
            }
        })
        await m.loadSetup()
        XCTAssertEqual(m.setupKeys.map(\.name), ["ANTHROPIC_API_KEY", "TINYFISH_API_KEY"])
        XCTAssertEqual(m.setupKeys.filter { $0.required && !$0.set }.map(\.name), ["ANTHROPIC_API_KEY"])
        let bad = await m.saveKey("ANTHROPIC_API_KEY", value: "bad")
        XCTAssertFalse(bad)
        XCTAssertEqual(m.notice, "Anthropic rejected that key.")
        let ok = await m.saveKey("ANTHROPIC_API_KEY", value: "sk-good")
        XCTAssertTrue(ok)
        XCTAssertEqual(box.history, [["name": "ANTHROPIC_API_KEY", "value": "sk-good"]])
    }

    func testAppListConnectOpensTheSignInPageAndRemoveDropsTheAccount() async {
        let box = Box()
        var opened: [URL] = []
        let m = AppModel(api: Fake { req in
            switch req {
            case let .renameApp(toolkit, accountId, alias): box.contexts = [toolkit, accountId, alias]; return [.success(event("result"))]
            case .apps: return [.success(event("result", ["available": true, "apps": [["slug": "gmail", "name": "Gmail", "group": "Google Workspace", "about": "Read and send email", "connected": true,
                                 "accounts": [["id": "a1", "status": "ACTIVE", "alias": "work"]]]]]))]
            case let .connectApp(toolkit, alias): box.history = [["toolkit": toolkit, "alias": alias]]; return [.success(event("result", ["url": "https://connect.composio.dev/link/lk_x"]))]
            case let .removeApp(toolkit, accountId): box.contexts = [toolkit, accountId]; return [.success(event("result"))]
            default: return [.success(event("result"))]
            }
        })
        m.openURL = { opened.append($0) }
        await m.loadApps()
        XCTAssertEqual(m.apps?.first?.name, "Gmail")
        XCTAssertEqual(m.apps?.first?.accounts.first?.alias, "work")
        await m.connect(app: "gmail", alias: "personal")
        XCTAssertEqual(box.history, [["toolkit": "gmail", "alias": "personal"]])
        XCTAssertEqual(opened, [URL(string: "https://connect.composio.dev/link/lk_x")!])
        await m.remove(app: "gmail", account: "a1")
        XCTAssertEqual(box.contexts, ["gmail", "a1"])
        XCTAssertEqual(m.apps?.first?.group, "Google Workspace")
        XCTAssertEqual(m.apps?.first?.about, "Read and send email")
        await m.rename(app: "gmail", account: "a1", to: "personal")
        XCTAssertEqual(box.contexts, ["gmail", "a1", "personal"])
    }

    func testAServerThatNeedsASignInOpensItsLoginPage() async {
        var opened: [URL] = []
        let m = AppModel(api: Fake { req in
            switch req {
            case .connectors: return [.success(event("result", ["servers": [["name": "Zentro", "tools": 0, "url": "https://mcp.example/mcp", "needsSignIn": true]]]))]
            case let .mcpSignIn(name): XCTAssertEqual(name, "Zentro"); return [.success(event("result", ["url": "https://auth.example/authorize?x=1"]))]
            default: return [.success(event("result"))]
            }
        })
        m.openURL = { opened.append($0) }
        await m.loadConnectors()
        XCTAssertEqual(m.connectors.first?.needsSignIn, true)
        await m.signIn(server: "Zentro")
        XCTAssertEqual(opened, [URL(string: "https://auth.example/authorize?x=1")!])
    }

    func testTheBrowserWindowFollowsStateAndFramesAndOnlySendsInputOnTheUsersTurn() async {
        let box = Box()
        let frame = Data([0xFF, 0xD8]).base64EncodedString()
        let m = AppModel(api: Fake(holdOpen: { if case .watchBrowser = $0 { true } else { false } }) { req in
            switch req {
            case .watchBrowser: return [.success(event("browser", ["state": "working"])),
                                        .success(event("browser", ["state": "needsUser", "reason": "Please log in", "url": "https://linear.app/login", "frame": frame]))]
            case let .browserInput(input): box.history.append(input.mapValues { "\($0)" }); return [.success(event("result"))]
            case let .browserResume(note): box.contexts = [note]; return [.success(event("result"))]
            default: return [.success(event("result"))]
            }
        })
        let watching = Task { await m.watchBrowserOnce() }
        for _ in 0..<100 where m.browser.state != "needsUser" { try? await Task.sleep(for: .milliseconds(5)) }
        defer { watching.cancel() }
        XCTAssertEqual(m.browser.state, "needsUser")
        XCTAssertEqual(m.browser.reason, "Please log in")
        XCTAssertEqual(m.browser.frame, Data([0xFF, 0xD8]))
        await m.browserType("me@example.com")
        await m.browserClick(x: 0.5, y: 0.25)
        XCTAssertEqual(box.history.first?["kind"], "type")
        XCTAssertEqual(box.history.last?["kind"], "click")
        await m.browserResume("logged in")
        XCTAssertEqual(box.contexts, ["logged in"])
        m.browser.state = "working"
        await m.browserType("ignored")
        XCTAssertEqual(box.history.count, 2, "nothing is sent while Jarvis is in control")
    }

    func testConnectorImagesAttachToTheAnswerAndLinkedImagesGoThroughTheCompanion() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let m = AppModel(api: Fake { req in
            switch req {
            case let .image(url, clicked):
                if url.contains("zentro") || clicked { return [.success(event("result", ["status": "ok", "mime": "image/png", "data": png.base64EncodedString()]))] }
                return [.success(event("result", ["status": "ask"]))]
            default: return [.success(event("image", ["mime": "image/png", "data": png.base64EncodedString()])), .success(event("result"))]
            }
        })
        m.question = "Make me a banner"; await m.ask()
        XCTAssertEqual(m.chat.last?.images, [png])
        if case .ready(let d) = await m.loadImage("https://cdn.zentro.example/a.png", clicked: false) { XCTAssertEqual(d, png) } else { XCTFail("trusted image should load") }
        if case .ask = await m.loadImage("https://elsewhere.example/a.png", clicked: false) {} else { XCTFail("unknown image should wait for a click") }
        if case .ready = await m.loadImage("https://elsewhere.example/a.png", clicked: true) {} else { XCTFail("a click loads it") }
    }
}

private final class Box: @unchecked Sendable { var contexts: [String] = []; var calls = 0; var history: [[String: String]] = [] }

/// A companion that starts answering and then goes quiet forever.
private struct Hang: CompanionAPI {
    func send(_ request: Request, id: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { c in c.yield(event("trace", ["stage": "memory", "nodes": [], "notes": 0])) }
    }
}
