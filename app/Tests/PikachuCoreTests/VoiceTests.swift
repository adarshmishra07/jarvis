import XCTest
@testable import PikachuCore

private final class FakeRecorder: Recorder, @unchecked Sendable {
    var samples: [Float] = []
    var started = 0
    func start() throws { started += 1 }
    func stop() -> [Float] { samples }
}

private struct FakeTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String { text }
}

private final class Sink: @unchecked Sendable { var texts: [String] = [] }

private func speech(seconds: Double) -> [Float] { (0..<Int(seconds * 16000)).map { Float(sin(Double($0) / 8)) * 0.2 } }

@MainActor
final class PushToTalkTests: XCTestCase {
    private func make(_ text: String, samples: [Float]) -> (PushToTalk, Sink, FakeRecorder) {
        let sink = Sink(), rec = FakeRecorder()
        rec.samples = samples
        let ptt = PushToTalk(recorder: rec, transcriber: FakeTranscriber(text: text)) { sink.texts.append($0) }
        return (ptt, sink, rec)
    }

    func testPressReleaseSendsOneTranscript() async {
        let (ptt, sink, _) = make("When is the Atlas launch?", samples: speech(seconds: 1.5))
        ptt.press(); await ptt.release()
        XCTAssertEqual(sink.texts, ["When is the Atlas launch?"])
        XCTAssertEqual(ptt.state, .idle)
    }

    func testShortTapSilenceAndHallucinationsSendNothing() async {
        for (text, samples) in [("hello there", speech(seconds: 0.2)), ("hello there", [Float](repeating: 0, count: 32000)), ("you", speech(seconds: 1)), ("Thank you.", speech(seconds: 1)), ("  ", speech(seconds: 1))] {
            let (ptt, sink, _) = make(text, samples: samples)
            ptt.press(); await ptt.release()
            XCTAssertEqual(sink.texts, [], "\(text) / \(samples.count)")
        }
    }

    func testPressWhileTranscribingIsIgnored() async {
        let (ptt, _, rec) = make("question", samples: speech(seconds: 1))
        ptt.press()
        let t = Task { await ptt.release() }
        ptt.press() // during transcribing or after; must not start a second recording while busy
        await t.value
        XCTAssertLessThanOrEqual(rec.started, 2)
        XCTAssertEqual(ptt.state == .recording || ptt.state == .idle, true)
    }

    func testReleaseWithoutPressDoesNothing() async {
        let (ptt, sink, _) = make("q", samples: speech(seconds: 1))
        await ptt.release()
        XCTAssertEqual(sink.texts, [])
    }
}

private final class FakeVoice: Voice, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    var spoken: [String] { lock.withLock { _log.filter { $0.hasPrefix("play ") }.map { String($0.dropFirst(5)) } } }
    var log: [String] { lock.withLock { _log } }
    var stopped = 0
    private func note(_ s: String) { lock.withLock { _log.append(s) } }
    func render(_ text: String) async -> AudioClip? {
        note("render \(text)"); try? await Task.sleep(for: .milliseconds(30))
        return AudioClip(samples: [0], sampleRate: 24_000)
    }
    func play(_ clip: AudioClip, _ text: String) async {
        note("play \(text)"); try? await Task.sleep(for: .milliseconds(80)); note("done \(text)")
    }
    func stop() { stopped += 1 }
}

final class StopPhraseTests: XCTestCase {
    func testJustSayingWaitOrStopOnlySilencesJarvis() {
        for t in ["Wait.", "Wait Wait Wait.", "stop", "Hold on!", "ruko", "bas", "okay stop"] { XCTAssertTrue(PushToTalk.isStopPhrase(t), t) }
        for t in ["Wait, when is the Orbit launch?", "Stop the Atlas build tomorrow", "Hello"] { XCTAssertFalse(PushToTalk.isStopPhrase(t), t) }
    }

    func testStoppingJarvisByNameNeedsNoGreeting() {
        for t in ["Jarvis stop", "Stop, Jarvis.", "Goodbye Jarvis", "Jarvis, goodbye.", "bye jarvis", "Okay Jarvis, stop", "Jervis stop"] {
            XCTAssertTrue(PushToTalk.isStopPhrase(t), t)
        }
        for t in ["Jarvis", "Jarvis, stop the deploy", "Goodbye to the old plan"] { XCTAssertFalse(PushToTalk.isStopPhrase(t), t) }
    }
}

final class UnfinishedTests: XCTestCase {
    /// A pause to think mid-sentence ("then there is a call at...") is not the end of the question.
    func testASentenceCutOffMidThoughtSoundsUnfinished() {
        for t in ["Then there is a call at.", "remind me about the", "I have a meeting with", "and", "Book it for, um", "मुझे याद दिलाना कि"] {
            XCTAssertTrue(PushToTalk.soundsUnfinished(t), t)
        }
        for t in ["What time is it?", "Remind me at five.", "Six thirty, I have to join.", "Who is it for?"] { XCTAssertFalse(PushToTalk.soundsUnfinished(t), t) }
    }
}

private final class MuteVoice: Voice, @unchecked Sendable {
    func render(_ text: String) async -> AudioClip? { nil }
    func play(_ clip: AudioClip, _ text: String) async {}
    func stop() {}
}

@MainActor
final class SpeakerTests: XCTestCase {
    func testSpeaksInOrderAndSkipsEmpty() async {
        let v = FakeVoice(), s = Speaker(voice: v)
        s.enqueue("One."); s.enqueue("  "); s.enqueue("Two.")
        await s.drain()
        XCTAssertEqual(v.spoken, ["One.", "Two."])
    }

    func testTheNextSentenceIsReadyBeforeThisOneEnds() async {
        let v = FakeVoice(), s = Speaker(voice: v)
        s.enqueue("One."); s.enqueue("Two.")
        await s.drain()
        let log = v.log
        XCTAssertLessThan(log.firstIndex(of: "render Two.")!, log.firstIndex(of: "done One.")!, "no gap: Two is rendered while One plays")
    }

    func testEachSentenceIsShownAsItStartsPlaying() async {
        let v = FakeVoice(), s = Speaker(voice: v)
        var shown: [String] = []
        s.enqueue("One.") { shown.append("One.") }
        s.enqueue("Two.") { shown.append("Two.") }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(shown, ["One."], "Two is not shown before it is heard")
        await s.drain()
        XCTAssertEqual(shown, ["One.", "Two."])
    }

    func testTextStillAppearsWhenTheVoiceCannotSpeak() async {
        let v = MuteVoice(), s = Speaker(voice: v)
        var shown: [String] = []
        s.enqueue("One.") { shown.append("One.") }
        await s.drain()
        XCTAssertEqual(shown, ["One."])
    }

    func testCancelDropsPendingSpeech() async {
        let v = FakeVoice(), s = Speaker(voice: v)
        s.enqueue("One."); s.enqueue("Two."); s.enqueue("Three.")
        try? await Task.sleep(for: .milliseconds(50))
        s.cancel()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(v.spoken, ["One."])
        XCTAssertGreaterThan(v.stopped, 0)
        XCTAssertEqual(s.pending, 0)
    }

    func testPendingTellsWhetherJarvisIsTalking() async {
        let v = FakeVoice(), s = Speaker(voice: v)
        s.enqueue("One."); s.enqueue("Two.")
        XCTAssertEqual(s.pending, 2)
        await s.drain()
        XCTAssertEqual(s.pending, 0)
    }
}
