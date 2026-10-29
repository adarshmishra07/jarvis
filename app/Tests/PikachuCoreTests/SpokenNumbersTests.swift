import XCTest
@testable import PikachuCore

final class SpokenNumbersTests: XCTestCase {
    private func say(_ s: String) -> String { SpokenNumbers.expand(s) }

    func testWholeNumbersBecomeWords() {
        XCTAssertEqual(say("It is 22 degrees."), "It is twenty two degrees.")
        XCTAssertEqual(say("You have 3 meetings and 15 emails."), "You have three meetings and fifteen emails.")
        XCTAssertEqual(say("Target is 10,000 signups"), "Target is ten thousand signups")
        XCTAssertEqual(say("Room 101"), "Room one hundred one")
    }

    func testTimesAreSaidTheWayPeopleSayThem() {
        XCTAssertEqual(say("It's 23:16."), "It's eleven sixteen PM.")
        XCTAssertEqual(say("Standup at 11:00 AM"), "Standup at eleven o'clock AM")
        XCTAssertEqual(say("The call is 7:30 to 8:05"), "The call is seven thirty to eight oh five")
        XCTAssertEqual(say("at 00:20"), "at twelve twenty AM")
    }

    func testDecimalsPercentsMoneyAndOrdinals() {
        XCTAssertEqual(say("It costs 0.25 credits"), "It costs zero point two five credits")
        XCTAssertEqual(say("Up 15% this week"), "Up fifteen percent this week")
        XCTAssertEqual(say("Plan is $19 a month"), "Plan is nineteen dollars a month")
        XCTAssertEqual(say("Pay ₹500 today"), "Pay five hundred rupees today")
        XCTAssertEqual(say("On the 22nd of October"), "On the twenty second of October")
    }

    func testTextWithoutNumbersIsUntouched() {
        XCTAssertEqual(say("No numbers here, Jarvis."), "No numbers here, Jarvis.")
        XCTAssertEqual(say("GPT-4 and Web3"), "GPT four and Web three")
    }
}
