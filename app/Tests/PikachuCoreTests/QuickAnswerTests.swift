import XCTest
@testable import PikachuCore

final class QuickAnswerTests: XCTestCase {
    // Thursday 22 October 2026, 22:42 in the test's time zone.
    private let zone = TimeZone(identifier: "Asia/Kolkata")!
    private var now: Date { DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: zone, year: 2026, month: 10, day: 22, hour: 22, minute: 42).date! }
    private func reply(_ q: String) -> String? { QuickAnswer.reply(to: q, now: now, timeZone: zone) }

    func testTheTimeIsAnsweredOnTheMac() {
        for q in ["What time is it?", "what's the time", "Tell me the time.", "time please", "What is the time now?", "current time",
                  "kitne baje hain", "time kya hai", "Jarvis, what time is it?",
                  "Can you tell me what's the time right now?", "I am wanting to know the time right now.", "What is the time right now?",
                  "Yes. What is the time right now?", "What's the time."] {
            XCTAssertEqual(reply(q), "It's 10:42 PM.", q)
        }
        XCTAssertEqual(reply("कितने बजे हैं?"), "अभी 10:42 बजे हैं।")
    }

    func testTheDateAndDay() {
        for q in ["What's the date today?", "what is today's date", "today's date", "aaj ki date kya hai"] {
            XCTAssertEqual(reply(q), "It's Thursday, 22 October.", q)
        }
        for q in ["What day is it?", "what day is today", "aaj kaun sa din hai"] {
            XCTAssertEqual(reply(q), "It's Thursday.", q)
        }
    }

    func testAnythingMoreGoesToJarvis() {
        for q in ["What time is my meeting?", "what time is it in London", "remind me of the date of the launch",
                  "what day is Diwali", "Time to go", "what's the date of my flight"] {
            XCTAssertNil(reply(q), q)
        }
    }
}
