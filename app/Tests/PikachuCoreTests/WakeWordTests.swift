import XCTest
@testable import PikachuCore

final class WakeWordTests: XCTestCase {
    func testHeyJarvisAloneStartsAConversation() {
        for heard in ["Hey Jarvis", "Hey, Jarvis.", "hey jarvis", "Hi Jarvis!", "Hello Jarvis", "hii jarvis", "Hey Jervis", "Hey Jarwis.", "Hey Javis"] {
            XCTAssertEqual(WakeWord.parse(heard), .listen, heard)
        }
    }

    func testTheWaysSpeechToTextWritesItStillWake() {
        for heard in ["Heyjarvis", "Hey-Jarvis.", "Hey Jarvice", "Hay Jarvis", "Hello Jarvis",
                      "Uh, hey Jarvis", "Um hey jarvis.", "So, hey Jarvis", "Oh hey Jarvis", "हे जार्विस", "हे जारविस।", "हाय जार्विस"] {
            XCTAssertEqual(WakeWord.parse(heard), .listen, heard)
        }
        XCTAssertEqual(WakeWord.parse("Uh hey Jarvis, what time is it?"), .ask("what time is it?"))
        XCTAssertEqual(WakeWord.parse("हे जार्विस, आज का मौसम कैसा है?"), .ask("आज का मौसम कैसा है?"))
    }

    func testAQuestionAfterTheWakeWordIsAskedRightAway() {
        XCTAssertEqual(WakeWord.parse("Hey Jarvis, what's on my calendar today?"), .ask("what's on my calendar today?"))
    }

    func testNoteTakingCommands() {
        XCTAssertEqual(WakeWord.parse("Hey Jarvis start taking notes"), .startNotes)
        XCTAssertEqual(WakeWord.parse("hey jarvis, take notes"), .startNotes)
        XCTAssertEqual(WakeWord.parse("Hey Jarvis, stop taking notes."), .stopNotes)
        XCTAssertEqual(WakeWord.parse("Hey Jarvis stop note taking"), .stopNotes)
    }

    func testEndingTheConversation() {
        for heard in ["Hey Jarvis stop", "Hey Jarvis, goodbye", "hey jarvis go to sleep", "Hey Jarvis that's all"] {
            XCTAssertEqual(WakeWord.parse(heard), .sleep, heard)
        }
    }

    func testTrainingLearnsHowYourHeyJarvisIsWritten() {
        XCTAssertEqual(WakeWord.learnable("Hey, Charvis."), "hey charvis")
        XCTAssertEqual(WakeWord.learnable("हे जार्विस।"), "हे जार्विस")
        for generic in ["Hey.", "Okay.", "Hey there", "Hello", "Thank you", "hey what is the weather like today in london"] {
            XCTAssertNil(WakeWord.learnable(generic), generic)
        }
        let learned = ["hey charvis"]
        XCTAssertNil(WakeWord.parse("Hey Charvis"), "not without training")
        XCTAssertEqual(WakeWord.parse("Hey Charvis", learned: learned), .listen)
        XCTAssertEqual(WakeWord.parse("Hey, Charvis, what time is it?", learned: learned), .ask("what time is it"))
        XCTAssertEqual(WakeWord.parse("hey charvis start taking notes", learned: learned), .startNotes)
        XCTAssertNil(WakeWord.parse("hey charvish is late", learned: learned), "the whole phrase, not a part of a word")
    }

    func testOrdinarySpeechIsIgnored() {
        for heard in ["I told him hey jarvis", "Hey, can you pass the salt", "Jarvis is in Iron Man", "Hey Jarvis-like assistants",
                      "Hey Travis", "Hey, Jarred.", "Hey Pika", "जार्विस कौन है", "So Jarvis said no", "Jarvis, what time is it?"] {
            XCTAssertNil(WakeWord.parse(heard), heard)
        }
    }
}
