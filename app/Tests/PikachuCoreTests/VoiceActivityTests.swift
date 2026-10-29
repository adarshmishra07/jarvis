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

final class VoiceActivityEndCheckTests: XCTestCase {
    private let speech = [Float](repeating: 0.2, count: 16_000)
    private let silence = { (s: Double) in [Float](repeating: 0, count: Int(s * 16_000)) }

    func testAFinishedSentenceEndsAfterAShortPause() {
        var vad = VoiceActivity()
        var asked = 0
        vad.endCheck = { _ in asked += 1; return true }
        let events = vad.feed(speech + silence(0.3))
        XCTAssertEqual(events.count, 2, "ended after 0.3 s, well before the 0.7 s rule")
        XCTAssertEqual(asked, 1)
    }

    func testAnUnfinishedSentenceWaitsLongerThanToday() {
        var vad = VoiceActivity()
        var asked = 0
        vad.endCheck = { _ in asked += 1; return false }
        XCTAssertEqual(vad.feed(speech + silence(1.0)).count, 1, "a 1 s pause mid-thought no longer cuts you off")
        XCTAssertEqual(vad.feed(silence(0.3)).count, 1, "but a long silence still ends the turn")
        XCTAssertEqual(asked, 1, "asked once per pause")
    }
}

final class SmartTurnTests: XCTestCase {
    /// Same signal as the Python reference (Hugging Face feature extractor + onnxruntime).
    private func signal(_ n: Int) -> [Float] {
        (0..<n).map { i in
            let t = Double(i) / 16_000
            return Float(0.3 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 1234.5 * t + 0.5) * t)
        }
    }

    func testFeaturesMatchWhisper() {
        for (n, expected) in [(48_000, [-0.147141, 0.863105, 0.521101, -0.286183, -0.286183]), (160_000, [0.023879, 0.752894, 0.256377, -0.298900, 0.735478])] {
            let x = WhisperFeatures.logMel(SmartTurn.lastWindow(signal(n)))
            XCTAssertEqual(x.count, 80 * 800)
            let got = [x.reduce(0, +) / Float(x.count), x[0 * 800 + 799], x[10 * 800 + 700], x[79 * 800 + 600], x[40 * 800 + 0]]
            for (g, e) in zip(got, expected) { XCTAssertEqual(Double(g), e, accuracy: 2e-3, "\(n) samples") }
        }
    }

    func testTheModelGivesTheSameAnswerAsPython() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../models/smart-turn-v3.2-cpu.onnx").standardized.path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "model not downloaded (scripts/build-app.sh fetches it)")
        let turn = try SmartTurn(modelPath: path)
        // The model is int8: onnxruntime builds differ by up to about 0.1 on it, never across the 0.5 line here.
        XCTAssertEqual(Double(try turn.probability(signal(48_000))), 0.412295, accuracy: 0.1)
        XCTAssertEqual(Double(try turn.probability(signal(160_000))), 0.946610, accuracy: 0.1)
    }
}
