import XCTest
@testable import PixSnapCore

final class AnnotationDocumentTests: XCTestCase {
    private func make(_ shape: AnnotationShape, lineWidth: CGFloat = 4) -> Annotation {
        Annotation(shape: shape, color: .red, lineWidth: lineWidth)
    }

    func testRectangleIsHitOnOutlineOnly() {
        let box = make(.rectangle(CGRect(x: 100, y: 100, width: 200, height: 100)))
        XCTAssertTrue(box.hitTest(CGPoint(x: 101, y: 150), tolerance: 4))
        XCTAssertFalse(box.hitTest(CGPoint(x: 200, y: 150), tolerance: 4))
        XCTAssertFalse(box.hitTest(CGPoint(x: 80, y: 150), tolerance: 4))
    }

    func testArrowIsHitNearItsLine() {
        let arrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 52, y: 48), tolerance: 4))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 80, y: 20), tolerance: 4))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 120, y: 120), tolerance: 4))
    }

    func testFrontMostAnnotationWins() {
        var document = AnnotationDocument(canvasSize: CGSize(width: 400, height: 300))
        let back = make(.mosaic(CGRect(x: 0, y: 0, width: 200, height: 200)))
        let front = make(.counter(1, center: CGPoint(x: 50, y: 50)))
        document.add(back)
        document.add(front)
        XCTAssertEqual(document.annotation(at: CGPoint(x: 50, y: 50))?.id, front.id)
        XCTAssertEqual(document.annotation(at: CGPoint(x: 150, y: 150))?.id, back.id)
        XCTAssertNil(document.annotation(at: CGPoint(x: 350, y: 250)))
    }

    func testCounterNumbersKeepIncreasingAfterDelete() {
        var document = AnnotationDocument(canvasSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(document.nextCounterNumber, 1)
        let first = make(.counter(1, center: .zero))
        document.add(first)
        document.add(make(.counter(2, center: .zero)))
        document.remove(id: first.id)
        XCTAssertEqual(document.nextCounterNumber, 3)
    }

    func testTranslateMovesEveryPointOfAnArrow() {
        let arrow = make(.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 20)))
        let moved = arrow.translated(dx: 5, dy: -5)
        XCTAssertEqual(moved.shape, .arrow(from: CGPoint(x: 15, y: 5), to: CGPoint(x: 55, y: 15)))
        XCTAssertEqual(moved.id, arrow.id)
    }

    func testCropIsClippedToCanvasAndTinyCropClears() {
        var document = AnnotationDocument(canvasSize: CGSize(width: 400, height: 300))
        document.setCrop(CGRect(x: 350, y: 250, width: -100, height: 200))
        XCTAssertEqual(document.crop, CGRect(x: 250, y: 250, width: 100, height: 50))
        XCTAssertEqual(document.outputRect, CGRect(x: 250, y: 250, width: 100, height: 50))

        document.setCrop(CGRect(x: 10, y: 10, width: 2, height: 50))
        XCTAssertNil(document.crop)
        XCTAssertEqual(document.outputRect, document.canvasRect)
    }
}
