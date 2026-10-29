import XCTest
@testable import PikachuCore

final class ScriptTests: XCTestCase {
    func testOnlyEnglishOrHindiIsAcceptedFromTheSpeechModel() {
        XCTAssertTrue(SpeechScript.accepts(language: "English", text: "Tell me about Asha."))
        XCTAssertTrue(SpeechScript.accepts(language: "Hindi", text: "Signups तो आ रहे हैं"))
        XCTAssertTrue(SpeechScript.accepts(language: "English,Hindi", text: "meeting cancel कर दो"))
        XCTAssertTrue(SpeechScript.accepts(language: nil, text: "No language given, English text."))
        // English said with an Indian accent, taken for Marathi: same script as Hindi, so the language is what tells.
        XCTAssertFalse(SpeechScript.accepts(language: "Marathi", text: "हाय, चल मी बाउट ड्रम एका प्लीज."))
        XCTAssertFalse(SpeechScript.accepts(language: "Nepali", text: "नमस्ते"))
        XCTAssertFalse(SpeechScript.accepts(language: nil, text: "嗨，你好。"), "no language given: the script still decides")
    }

    func testEnglishHindiAndHinglishPassOtherScriptsDoNot() {
        XCTAssertTrue(SpeechScript.isEnglishOrHindi("Hi, how are you? It's 7:30 PM."))
        XCTAssertTrue(SpeechScript.isEnglishOrHindi("Nimbus पे जाके कुछ भी change करेगा"))
        XCTAssertFalse(SpeechScript.isEnglishOrHindi("嗨，你好。"))
        XCTAssertFalse(SpeechScript.isEnglishOrHindi("こんにちは"))
        XCTAssertFalse(SpeechScript.isEnglishOrHindi("Привет"))
    }

    func testVocabularyBecomesAShortContextLine() {
        XCTAssertEqual(SpeechScript.context(vocabulary: ["Acme", "Zentro"]), "Names and terms that may come up: Acme, Zentro.")
        XCTAssertEqual(SpeechScript.context(vocabulary: []), "")
    }

    func testSpellingFixesWholeWordsInAnyCase() {
        let map = ["zentra": "Zentro"]
        XCTAssertEqual(SpeechScript.fixSpelling("When is the Zentra launch? zentra.", map), "When is the Zentro launch? Zentro.")
        XCTAssertEqual(SpeechScript.fixSpelling("zentray roads", map), "zentray roads")
    }

    /// On noise the speech model can "hear" its own list of expected words: that is never something you said.
    func testTheWordListReadBackIsNotSpeech() {
        let words = ["Hey Pika", "Zentro", "Linear", "Figma", "Slack", "Jordan", "Riya", "Leo", "Staging (also called stage)"]
        XCTAssertTrue(SpeechScript.isContextEcho("Zentro, Linear, Figma, Slack, Jordan, Riya, Leo, Staging (also called stage).", vocabulary: words))
        XCTAssertTrue(SpeechScript.isContextEcho("Names and terms that may come up: Zentro, Linear.", vocabulary: words))
        XCTAssertFalse(SpeechScript.isContextEcho("Ask Jordan and Riya about the Linear ticket.", vocabulary: words))
        XCTAssertFalse(SpeechScript.isContextEcho("Linear, Figma and Slack are all down today.", vocabulary: words))
        XCTAssertFalse(SpeechScript.isContextEcho("Hey Pika", vocabulary: words))
    }
}
