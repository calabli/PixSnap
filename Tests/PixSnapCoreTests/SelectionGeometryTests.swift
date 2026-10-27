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
}
