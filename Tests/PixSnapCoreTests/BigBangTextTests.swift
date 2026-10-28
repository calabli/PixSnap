import XCTest
@testable import PixSnapCore

final class BigBangTextTests: XCTestCase {
    /// Ranges of the given substrings, in order.
    private func ranges(_ words: [String], in line: String) -> [Range<String.Index>] {
        var from = line.startIndex
        return words.map { word in
            let range = line.range(of: word, range: from ..< line.endIndex)!
            from = range.upperBound
            return range
        }
    }

    func testKeepsPunctuationBetweenWords() {
        let line = "金额：¥1,280.00（已付）"
        let pieces = BigBangText.pieces(of: line, words: ranges(["金额", "1,280.00", "已付"], in: line), lineNumber: 0)
        XCTAssertEqual(pieces.map(\.text), ["金额", "：¥", "1,280.00", "（", "已付", "）"])
        XCTAssertEqual(pieces.map(\.isWord), [true, false, true, false, true, false])
    }

    func testDropsSpacesAndSplitsPunctuationRuns() {
        let line = "Hello, world !  ok"
        let pieces = BigBangText.pieces(of: line, words: ranges(["Hello", "world", "ok"], in: line), lineNumber: 2)
        XCTAssertEqual(pieces.map(\.text), ["Hello", ",", "world", "!", "ok"])
        XCTAssertTrue(pieces.allSatisfy { $0.line == 2 })
    }

    func testJoinsWithSpacesOnlyBetweenSpacedWords() {
        let pieces = [
            BigBangText.Piece(text: "订单", isWord: true, line: 0), BigBangText.Piece(text: "详情", isWord: true, line: 0),
            BigBangText.Piece(text: "Order", isWord: true, line: 0), BigBangText.Piece(text: "ID", isWord: true, line: 0),
            BigBangText.Piece(text: "：", isWord: false, line: 0), BigBangText.Piece(text: "42", isWord: true, line: 0),
        ]
        XCTAssertEqual(BigBangText.join(pieces), "订单详情Order ID：42")
    }

    func testBreaksLinesWhereNeeded() {
        let pieces = [
            BigBangText.Piece(text: "first", isWord: true, line: 0), BigBangText.Piece(text: "second", isWord: true, line: 1),
            BigBangText.Piece(text: "中文", isWord: true, line: 1), BigBangText.Piece(text: "接着", isWord: true, line: 2),
            BigBangText.Piece(text: "far", isWord: true, line: 5),
        ]
        // English across a line: a line break (it would otherwise need a space); Chinese runs on;
        // skipping lines always breaks.
        XCTAssertEqual(BigBangText.join(pieces), "first\nsecond中文接着\nfar")
    }
}
