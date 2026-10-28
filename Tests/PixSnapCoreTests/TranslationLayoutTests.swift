@testable import PixSnapCore
import XCTest

final class TranslationLayoutTests: XCTestCase {
    /// A line `height` tall whose top is at `top`, both measured down from the image's top edge.
    private func line(_ text: String, x: Double = 0.1, width: Double = 0.8, top: Double, height: Double = 0.04) -> (text: String, box: CGRect) {
        (text, CGRect(x: x, y: 1 - top - height, width: width, height: height))
    }

    func testJoinsWrappedLinesIntoOneParagraph() {
        let paragraphs = TranslationLayout.paragraphs([
            line("Screenshots are kept on the clothesline", top: 0.1),
            line("until you take them down", width: 0.5, top: 0.15),
        ], aspectRatio: 1)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "Screenshots are kept on the clothesline until you take them down")
        XCTAssertEqual(paragraphs[0].lineCount, 2)
        XCTAssertEqual(paragraphs[0].box.minY, 1 - 0.19, accuracy: 0.0001)
    }

    func testJoinsChineseLinesWithoutASpace() {
        let paragraphs = TranslationLayout.paragraphs([line("截图会一直挂在晾衣绳上，", top: 0.1), line("直到你取下来", width: 0.4, top: 0.15)], aspectRatio: 1)
        XCTAssertEqual(paragraphs.map(\.text), ["截图会一直挂在晾衣绳上，直到你取下来"])
    }

    func testMendsAHyphenatedBreak() {
        XCTAssertEqual(TranslationLayout.joined("transla-", "tion"), "translation")
        XCTAssertEqual(TranslationLayout.joined("well-", "Known"), "well- Known")
    }

    func testKeepsApartLinesFarApartOrOfAnotherSize() {
        let paragraphs = TranslationLayout.paragraphs([
            line("Settings", top: 0.05, height: 0.08),
            line("Rope style and color", top: 0.15),
            line("Keep history for 30 days", top: 0.4),
        ], aspectRatio: 1)
        XCTAssertEqual(paragraphs.count, 3)
    }

    func testALabelOrAFullStopEndsTheParagraph() {
        let paragraphs = TranslationLayout.paragraphs([
            line("Copy", width: 0.1, top: 0.1),
            line("Save the picture to a folder you choose", top: 0.15),
            line("It was saved.", top: 0.2),
            line("Next paragraph", top: 0.25),
        ], aspectRatio: 1)
        XCTAssertEqual(paragraphs.map(\.text), ["Copy", "Save the picture to a folder you choose It was saved.", "Next paragraph"])
    }

    func testKeepsApartLinesStartingElsewhere() {
        let paragraphs = TranslationLayout.paragraphs([line("Name", width: 0.2, top: 0.1), line("PixSnap", x: 0.5, width: 0.3, top: 0.1)], aspectRatio: 1)
        XCTAssertEqual(paragraphs.count, 2)
    }

    func testSuggestsATargetLanguage() {
        XCTAssertEqual(TranslationTarget.suggested(forSource: "en", preferred: nil), .simplifiedChinese)
        XCTAssertEqual(TranslationTarget.suggested(forSource: "zh-Hans", preferred: nil), .english)
        XCTAssertEqual(TranslationTarget.suggested(forSource: "ja", preferred: .english), .english)
        // The chosen language isn't the one the screenshot is already in.
        XCTAssertEqual(TranslationTarget.suggested(forSource: "zh-Hant", preferred: .simplifiedChinese), .english)
        XCTAssertTrue(TranslationTarget.matches(.english, "en"))
        XCTAssertFalse(TranslationTarget.matches(.english, "zh-Hans"))
    }
}
