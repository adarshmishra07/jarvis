import XCTest
@testable import PikachuCore

final class VoiceActivityTests: XCTestCase {
    private func tone(_ seconds: Double, amp: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amp * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }
    private let silence = { (s: Double) in [Float](repeating: 0, count: Int(s * 16_000)) }

    func testSpeechThenAPauseGivesOneUtteranceWithALeadIn() {
        var vad = VoiceActivity()
        var events = vad.feed(silence(0.5))
        XCTAssertEqual(events, [])
        events = vad.feed(tone(1.0, amp: 0.2))
        XCTAssertEqual(events, [.started])
        events = vad.feed(silence(1.0))
        guard case let .ended(samples)? = events.first, events.count == 1 else { return XCTFail("expected one utterance") }
        XCTAssertGreaterThan(samples.count, Int(1.2 * 16_000), "speech plus the lead-in before it")
        XCTAssertLessThan(samples.count, Int(2.3 * 16_000))
    }

    func testAShortClickIsIgnored() {
        var vad = VoiceActivity()
        XCTAssertEqual(vad.feed(silence(0.3) + tone(0.05, amp: 0.3) + silence(1.0)), [])
    }

    func testAShortPauseMidSentenceDoesNotEndIt() {
        var vad = VoiceActivity()
        let events = vad.feed(tone(0.6, amp: 0.2) + silence(0.3) + tone(0.6, amp: 0.2) + silence(1.0))
        XCTAssertEqual(events.filter { $0 == .started }.count, 1)
        XCTAssertEqual(events.count, 2)
    }

    func testWhileJarvisSpeaksOnlyLouderSpeechCounts() {
        var vad = VoiceActivity()
        vad.raised = true
        XCTAssertEqual(vad.feed(tone(1.0, amp: 0.025) + silence(1.0)), [], "quiet leftover echo is not you")
        XCTAssertEqual(vad.feed(tone(0.5, amp: 0.2)), [.started])
    }
}

final class VoiceActivityFinishTests: XCTestCase {
    func testStoppingMidSentenceHandsBackWhatWasSaidSoFar() {
        var vad = VoiceActivity()
        let loud = [Float](repeating: 0.2, count: VoiceActivity.frame * 20)
        XCTAssertEqual(vad.feed(loud).count, 1, "speech started")
        let rest = vad.finish()
        XCTAssertNotNil(rest)
        XCTAssertGreaterThan(rest!.count, VoiceActivity.frame * 10)
        XCTAssertNil(vad.finish(), "nothing twice")
        var quiet = VoiceActivity()
        _ = quiet.feed([Float](repeating: 0, count: VoiceActivity.frame * 5))
        XCTAssertNil(quiet.finish(), "silence hands back nothing")
    }
}
