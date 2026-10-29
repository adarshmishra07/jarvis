import XCTest
@testable import PikachuCore

final class EchoFilterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func tone(_ seconds: Double, _ level: Float) -> [Float] { (0..<Int(seconds * 16_000)).map { level * sin(Float($0) * 0.3) } }

    func testWhatTheMicHearsWhileTheCallIsTalkingIsTheCallComingOutOfTheSpeakers() {
        var echo = EchoFilter()
        echo.system(tone(2, 0.2), endingAt: t0.addingTimeInterval(2)) // the call talks from 0 s to 2 s
        XCTAssertGreaterThan(echo.overlap(from: t0.addingTimeInterval(0.5), to: t0.addingTimeInterval(1.5)), 0.9)
        XCTAssertTrue(echo.isEcho(from: t0.addingTimeInterval(0.5), to: t0.addingTimeInterval(1.5)))
    }

    func testYouTalkingWhileTheCallIsQuietIsKept() {
        var echo = EchoFilter()
        echo.system(tone(2, 0.2), endingAt: t0.addingTimeInterval(2))
        echo.system(tone(3, 0.0005), endingAt: t0.addingTimeInterval(5)) // near silence from 2 s to 5 s
        XCTAssertEqual(echo.overlap(from: t0.addingTimeInterval(3), to: t0.addingTimeInterval(4)), 0, accuracy: 0.01)
        XCTAssertFalse(echo.isEcho(from: t0.addingTimeInterval(3), to: t0.addingTimeInterval(4)))
        XCTAssertFalse(echo.isEcho(from: t0.addingTimeInterval(1.6), to: t0.addingTimeInterval(4)), "mostly you: kept")
    }

    func testOldSoundIsForgotten() {
        var echo = EchoFilter()
        echo.system(tone(1, 0.2), endingAt: t0.addingTimeInterval(1))
        echo.system(tone(1, 0.0), endingAt: t0.addingTimeInterval(200))
        XCTAssertEqual(echo.overlap(from: t0, to: t0.addingTimeInterval(1)), 0, "kept for a minute at most")
    }
}
