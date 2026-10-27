import XCTest
@testable import PixSnapCore

/// The development Mac's built-in display: 1800×1169 points with a 38-point notch.
final class NotchGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let left = CGRect(x: 0, y: 1131, width: 800, height: 38)
    private let right = CGRect(x: 1000, y: 1131, width: 800, height: 38)

    func testFindsTheNotchBetweenTheMenuBarAreas() {
        XCTAssertEqual(NotchGeometry.notchRect(screenFrame: screen, topLeftArea: left, topRightArea: right, safeAreaTop: 38),
                       CGRect(x: 800, y: 1131, width: 200, height: 38))
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: screen, topLeftArea: nil, topRightArea: nil, safeAreaTop: 0))
    }

    func testStandInHangsFromTheTopCenter() {
        let monitor = CGRect(x: -903, y: 1169, width: 3360, height: 1890)
        XCTAssertEqual(NotchGeometry.standInRect(screenFrame: monitor), CGRect(x: 717, y: 3051, width: 120, height: 8))
    }

    func testHoverGrowsDownAndOutward() {
        let notch = CGRect(x: 800, y: 1131, width: 200, height: 38)
        let hover = NotchGeometry.hoverRect(for: notch)
        XCTAssertEqual(hover.maxY, notch.maxY)
        XCTAssertEqual(hover.midX, notch.midX)
        XCTAssertEqual(hover.size, CGSize(width: 240, height: 58))
    }

    func testOpenPanelStaysOnScreen() {
        let notch = CGRect(x: 800, y: 1131, width: 200, height: 38)
        let open = NotchGeometry.openRect(size: CGSize(width: 960, height: 400), under: notch, screenFrame: screen)
        XCTAssertEqual(open, CGRect(x: 420, y: 769, width: 960, height: 400))

        // A handle near the right edge pushes the panel back inside the margin.
        let nearEdge = CGRect(x: 1700, y: 1161, width: 80, height: 8)
        let pushed = NotchGeometry.openRect(size: CGSize(width: 960, height: 400), under: nearEdge, screenFrame: screen)
        XCTAssertEqual(pushed.maxX, 1776)
        // Wider than the screen: shrinks to fit.
        XCTAssertEqual(NotchGeometry.openRect(size: CGSize(width: 3000, height: 400), under: notch, screenFrame: screen).width, 1752)
    }

    func testPullingInterpolatesFromTheSameTopEdge() {
        let notch = CGRect(x: 800, y: 1131, width: 200, height: 38)
        let open = CGRect(x: 420, y: 769, width: 960, height: 400)
        XCTAssertEqual(NotchGeometry.frame(from: notch, to: open, progress: 0), notch)
        XCTAssertEqual(NotchGeometry.frame(from: notch, to: open, progress: 1), open)
        let half = NotchGeometry.frame(from: notch, to: open, progress: 0.5)
        XCTAssertEqual(half.maxY, 1169)
        XCTAssertEqual(half.size, CGSize(width: 580, height: 219))

        XCTAssertEqual(NotchGeometry.progress(forDrag: 181, collapsed: notch, open: open), 0.5, accuracy: 0.001)
        XCTAssertEqual(NotchGeometry.progress(forDrag: -20, collapsed: notch, open: open), 0)
        XCTAssertEqual(NotchGeometry.progress(forDrag: 900, collapsed: notch, open: open), 1)
    }
}
