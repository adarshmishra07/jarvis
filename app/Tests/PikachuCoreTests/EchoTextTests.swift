import XCTest
@testable import PikachuCore

final class EchoTextTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func line(_ s: Side, _ text: String, _ dt: TimeInterval) -> MeetingLine { MeetingLine(at: t0.addingTimeInterval(dt), speaker: s, text: text) }

    func testYourLineThatRepeatsTheCallIsDropped() {
        var m = Meeting()
        m.add(line(.them, "We will be shipping half of the templates, which is twelve screens.", 0))
        m.add(line(.me, "We will be shiping half of the templates, which is twelve screens.", 0.4))
        XCTAssertEqual(m.lines.map(\.speaker), [.them])
    }

    func testAnEchoTranscribedBeforeTheCallLineIsRemovedWhenTheCallLineArrives() {
        var m = Meeting()
        m.add(line(.me, "So that and then we are moving the Atlas launch to next month.", 0))
        m.add(line(.them, "So that, and then we are moving the Atlas launch to next month.", 3))
        XCTAssertEqual(m.lines.map(\.speaker), [.them])
    }

    func testYourOwnWordsStay() {
        var m = Meeting()
        m.add(line(.them, "There is a gap of two weeks in the plan.", 0))
        m.add(line(.me, "Can we bring it down to one week, I hope?", 2))
        m.add(line(.me, "Okay.", 3)) // too short to judge
        m.add(line(.me, "There is a gap of two weeks in the plan.", 40)) // said much later: you repeating it
        XCTAssertEqual(m.lines.count, 4)
    }
}
