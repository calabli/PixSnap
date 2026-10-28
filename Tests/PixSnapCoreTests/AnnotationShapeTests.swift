import XCTest
@testable import PixSnapCore

final class AnnotationShapeTests: XCTestCase {
    private func annotation(_ shape: AnnotationShape, width: CGFloat = 4) -> Annotation {
        Annotation(shape: shape, color: .red, lineWidth: width)
    }

    func testPenIsHitAlongItsStrokeOnly() {
        let pen = annotation(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]))
        XCTAssertTrue(pen.hitTest(CGPoint(x: 50, y: 3), tolerance: 2))
        XCTAssertTrue(pen.hitTest(CGPoint(x: 102, y: 60), tolerance: 2))
        XCTAssertFalse(pen.hitTest(CGPoint(x: 50, y: 50), tolerance: 2))
        XCTAssertEqual(pen.bounds, CGRect(x: -2, y: -2, width: 104, height: 104))
    }

    func testHighlightIsWiderThanItsLineWidth() {
        let marker = annotation(.highlight([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]))
        XCTAssertEqual(marker.strokeWidth, 16)
        // 8 points out is still on the 16-point-wide stroke.
        XCTAssertTrue(marker.hitTest(CGPoint(x: 50, y: 8), tolerance: 0))
        XCTAssertFalse(marker.hitTest(CGPoint(x: 50, y: 12), tolerance: 0))
    }

    func testEllipseIsHitNearItsOutline() {
        let ellipse = annotation(.ellipse(CGRect(x: 0, y: 0, width: 200, height: 100)))
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 100, y: 1), tolerance: 3))
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 199, y: 50), tolerance: 3))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 100, y: 50), tolerance: 3))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 5, y: 5), tolerance: 3))
    }

    func testMagnifierIsHitInsideItsCircle() {
        let lens = annotation(.magnifier(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(lens.hitTest(CGPoint(x: 50, y: 50), tolerance: 0))
        XCTAssertFalse(lens.hitTest(CGPoint(x: 3, y: 3), tolerance: 0))
    }

    func testEveryNewShapeMoves() {
        let shapes: [AnnotationShape] = [
            .pen([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 5)]), .highlight([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 5)]),
            .line(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 5, y: 5)), .ellipse(CGRect(x: 1, y: 1, width: 4, height: 4)),
            .blur(CGRect(x: 1, y: 1, width: 4, height: 4)), .magnifier(CGRect(x: 1, y: 1, width: 4, height: 4)),
        ]
        for shape in shapes {
            let original = annotation(shape)
            let moved = original.translated(dx: 10, dy: -3)
            XCTAssertEqual(moved.bounds, original.bounds.offsetBy(dx: 10, dy: -3), "\(shape)")
        }
    }

    func testShiftSnapsLinesTo45Degrees() {
        let end = Annotation.snapped(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(end.x, hypot(100, 8), accuracy: 0.001)
        XCTAssertEqual(end.y, 0, accuracy: 0.001)
        let diagonal = Annotation.snapped(from: .zero, to: CGPoint(x: 100, y: 90))
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
    }
}
