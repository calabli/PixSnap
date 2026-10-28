import XCTest
@testable import PixSnapCore

final class ScrollStitcherTests: XCTestCase {
    private let width = 40

    /// A long "page": every row different, with some blank rows like paragraph gaps.
    private func page(rows: Int, seed: UInt32 = 1) -> [[UInt8]] {
        var state = seed
        return (0 ..< rows).map { row in
            if row % 9 == 4 { return [UInt8](repeating: 255, count: width * 4) }
            return (0 ..< width * 4).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 24)
            }
        }
    }

    private func frame(_ rows: ArraySlice<[UInt8]>, header: [[UInt8]] = [], footer: [[UInt8]] = []) -> [UInt8] {
        (header + rows + footer).flatMap { $0 }
    }

    func testStitchesFramesScrolledByDifferentAmounts() {
        let content = page(rows: 400)
        let stitcher = ScrollStitcher(width: width, frameHeight: 100)
        XCTAssertEqual(stitcher.add(frame(content[0 ..< 100])), .started)
        XCTAssertEqual(stitcher.add(frame(content[30 ..< 130])), .added(rows: 30))
        XCTAssertEqual(stitcher.add(frame(content[30 ..< 130])), .unchanged)
        XCTAssertEqual(stitcher.add(frame(content[95 ..< 195])), .added(rows: 65))
        XCTAssertEqual(stitcher.add(frame(content[300 ..< 400])), .lost)
        XCTAssertEqual(stitcher.add(frame(content[180 ..< 280])), .added(rows: 85))
        XCTAssertEqual(stitcher.pixels, content[0 ..< 280].flatMap { $0 })
    }

    func testKeepsStickyHeaderAndFooterOnce() {
        let content = page(rows: 300)
        let header = page(rows: 10, seed: 7), footer = page(rows: 6, seed: 9)
        let stitcher = ScrollStitcher(width: width, frameHeight: 100)
        // 84 rows of content between the header and footer.
        stitcher.add(frame(content[0 ..< 84], header: header, footer: footer))
        XCTAssertEqual(stitcher.add(frame(content[40 ..< 124], header: header, footer: footer)), .added(rows: 40))
        XCTAssertEqual(stitcher.add(frame(content[100 ..< 184], header: header, footer: footer)), .added(rows: 60))
        XCTAssertEqual(stitcher.pixels, (header + content[0 ..< 184] + footer).flatMap { $0 })
    }

    func testScrollingUpAddsAbove() {
        let content = page(rows: 300)
        let stitcher = ScrollStitcher(width: width, frameHeight: 100)
        stitcher.add(frame(content[150 ..< 250]))
        XCTAssertEqual(stitcher.add(frame(content[110 ..< 210])), .addedAbove(rows: 40))
        XCTAssertEqual(stitcher.add(frame(content[40 ..< 140])), .addedAbove(rows: 70))
        XCTAssertEqual(stitcher.pixels, content[40 ..< 250].flatMap { $0 })
    }

    func testScrollingBackOverTakenRowsThenOn() {
        let content = page(rows: 400)
        let stitcher = ScrollStitcher(width: width, frameHeight: 100)
        stitcher.add(frame(content[0 ..< 100]))
        stitcher.add(frame(content[60 ..< 160]))
        stitcher.add(frame(content[130 ..< 230]))
        // Back up to look again: nothing new, nothing doubled.
        XCTAssertEqual(stitcher.add(frame(content[70 ..< 170])), .moved)
        XCTAssertEqual(stitcher.add(frame(content[20 ..< 120])), .moved)
        XCTAssertEqual(stitcher.height, 230)
        // And down again past where it was.
        XCTAssertEqual(stitcher.add(frame(content[100 ..< 200])), .moved)
        XCTAssertEqual(stitcher.add(frame(content[180 ..< 280])), .added(rows: 50))
        XCTAssertEqual(stitcher.pixels, content[0 ..< 280].flatMap { $0 })
    }

    func testStickyBandsStayOnceWhenScrollingUp() {
        let content = page(rows: 300)
        let header = page(rows: 10, seed: 7), footer = page(rows: 6, seed: 9)
        let stitcher = ScrollStitcher(width: width, frameHeight: 100)
        stitcher.add(frame(content[150 ..< 234], header: header, footer: footer))
        XCTAssertEqual(stitcher.add(frame(content[100 ..< 184], header: header, footer: footer)), .addedAbove(rows: 50))
        // Back down past the first view: 20 new rows below it.
        XCTAssertEqual(stitcher.add(frame(content[170 ..< 254], header: header, footer: footer)), .added(rows: 20))
        XCTAssertEqual(stitcher.pixels, (header + content[100 ..< 254] + footer).flatMap { $0 })
    }

    func testToleratesAFewChangedRows() {
        let content = page(rows: 300)
        let stitcher = ScrollStitcher(width: width, frameHeight: 100)
        stitcher.add(frame(content[0 ..< 100]))
        // A blinking cursor: one row differs in the next frame.
        var moved = Array(content[20 ..< 120])
        moved[50] = page(rows: 1, seed: 99)[0]
        XCTAssertEqual(stitcher.add(moved.flatMap { $0 }), .added(rows: 20))
        XCTAssertEqual(stitcher.height, 120)
    }

    func testStopsAtTheMaximumHeight() {
        let content = page(rows: 300)
        let stitcher = ScrollStitcher(width: width, frameHeight: 100, maximumHeight: 150)
        stitcher.add(frame(content[0 ..< 100]))
        XCTAssertEqual(stitcher.add(frame(content[80 ..< 180])), .added(rows: 50))
        XCTAssertEqual(stitcher.add(frame(content[120 ..< 220])), .full)
        XCTAssertEqual(stitcher.height, 150)
    }
}
