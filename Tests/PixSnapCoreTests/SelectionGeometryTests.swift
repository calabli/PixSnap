import XCTest
@testable import PixSnapCore

final class SelectionGeometryTests: XCTestCase {
    func testRectNormalizesAnyDragDirection() {
        let rect = SelectionGeometry.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 20))
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 40, height: 60))
    }

    func testTinyDragCountsAsClick() {
        XCTAssertFalse(SelectionGeometry.isDrag(CGRect(x: 0, y: 0, width: 3, height: 100)))
        XCTAssertTrue(SelectionGeometry.isDrag(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    func testPixelRectFlipsAndScalesForRetina() {
        // 1000×800 pt screen captured at 2x. A selection in the top-left corner of the view
        // (bottom-left origin) must land at the top-left of the image (top-left origin).
        let pixel = SelectionGeometry.pixelRect(
            forViewRect: CGRect(x: 0, y: 700, width: 100, height: 100),
            viewSize: CGSize(width: 1000, height: 800),
            imageSize: CGSize(width: 2000, height: 1600)
        )
        XCTAssertEqual(pixel, CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    func testPixelRectClipsToScreenAndRoundsOutward() {
        let pixel = SelectionGeometry.pixelRect(
            forViewRect: CGRect(x: 950.3, y: -20, width: 100, height: 50.2),
            viewSize: CGSize(width: 1000, height: 800),
            imageSize: CGSize(width: 2000, height: 1600)
        )
        XCTAssertEqual(pixel, CGRect(x: 1900, y: 1539, width: 100, height: 61))
    }

    func testPixelRectOutsideViewIsZero() {
        let pixel = SelectionGeometry.pixelRect(
            forViewRect: CGRect(x: 2000, y: 2000, width: 10, height: 10),
            viewSize: CGSize(width: 1000, height: 800),
            imageSize: CGSize(width: 2000, height: 1600)
        )
        XCTAssertEqual(pixel, .zero)
    }

    func testHandleFindsCornersEdgesAndNothingInside() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 103, y: 197), in: rect, tolerance: 6), .topLeft)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 250, y: 96), in: rect, tolerance: 6), .bottom)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 305, y: 150), in: rect, tolerance: 6), .right)
        XCTAssertNil(SelectionGeometry.handle(at: CGPoint(x: 200, y: 150), in: rect, tolerance: 6))
        XCTAssertNil(SelectionGeometry.handle(at: CGPoint(x: 320, y: 150), in: rect, tolerance: 6))
    }

    func testHandleOnTinySelectionPicksNearerEdge() {
        let rect = CGRect(x: 100, y: 100, width: 4, height: 50)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 101, y: 125), in: rect, tolerance: 6), .left)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 104, y: 125), in: rect, tolerance: 6), .right)
    }

    func testResizeMovesOnlyHeldEdgesAndFlips() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SelectionGeometry.resized(rect, by: .right, delta: CGSize(width: 50, height: 30), within: bounds),
                       CGRect(x: 100, y: 100, width: 250, height: 100))
        XCTAssertEqual(SelectionGeometry.resized(rect, by: .topLeft, delta: CGSize(width: -20, height: 10), within: bounds),
                       CGRect(x: 80, y: 100, width: 220, height: 110))
        // The left edge dragged past the right one.
        XCTAssertEqual(SelectionGeometry.resized(rect, by: .left, delta: CGSize(width: 260, height: 0), within: bounds),
                       CGRect(x: 300, y: 100, width: 60, height: 100))
    }

    func testResizeStopsAtScreenEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SelectionGeometry.resized(rect, by: .bottomLeft, delta: CGSize(width: -500, height: -500), within: bounds),
                       CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    func testMoveKeepsSizeAndStaysOnScreen() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SelectionGeometry.moved(rect, by: CGSize(width: 30, height: -40), within: bounds),
                       CGRect(x: 130, y: 60, width: 200, height: 100))
        XCTAssertEqual(SelectionGeometry.moved(rect, by: CGSize(width: 2000, height: 2000), within: bounds),
                       CGRect(x: 800, y: 700, width: 200, height: 100))
    }
}

