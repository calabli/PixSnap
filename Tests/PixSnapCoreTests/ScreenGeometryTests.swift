import XCTest
@testable import PixSnapCore

/// Uses the layout of the development Mac: a 1800×1169 built-in display (primary) and a
/// 3360×1890 monitor above it, shifted 903 points to the left.
final class ScreenGeometryTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let monitor = CGRect(x: -903, y: 1169, width: 3360, height: 1890)

    func testConvertsCoreGraphicsRectsOnBothDisplays() {
        // The monitor's CGDisplayBounds is (-903, -1890, 3360, 1890): above the primary, so y < 0.
        XCTAssertEqual(ScreenGeometry.appKitRect(fromCGRect: CGRect(x: -903, y: -1890, width: 3360, height: 1890),
                                                 primaryScreenHeight: 1169), monitor)
        // A window near the monitor's top-left corner.
        XCTAssertEqual(ScreenGeometry.appKitRect(fromCGRect: CGRect(x: -800, y: -1850, width: 800, height: 600),
                                                 primaryScreenHeight: 1169),
                       CGRect(x: -800, y: 2419, width: 800, height: 600))
        // A window on the built-in display.
        XCTAssertEqual(ScreenGeometry.appKitRect(fromCGRect: CGRect(x: 100, y: 38, width: 600, height: 400),
                                                 primaryScreenHeight: 1169),
                       CGRect(x: 100, y: 731, width: 600, height: 400))
    }

    func testScreenUnderMouseComesFirst() {
        let frames = [builtIn, monitor]
        XCTAssertEqual(ScreenGeometry.indicesStartingWithScreen(under: CGPoint(x: -500, y: 2000), in: frames), [1, 0])
        XCTAssertEqual(ScreenGeometry.indicesStartingWithScreen(under: CGPoint(x: 900, y: 500), in: frames), [0, 1])
        // Off every screen: original order.
        XCTAssertEqual(ScreenGeometry.indicesStartingWithScreen(under: CGPoint(x: 5000, y: 5000), in: frames), [0, 1])
    }

    func testSharedEdgeBelongsToOneScreen() {
        // The line between the two displays (y = 1169) is the built-in display's top edge.
        let edge = CGPoint(x: 900, y: 1169)
        XCTAssertTrue(ScreenGeometry.screen(builtIn, containsMouse: edge))
        XCTAssertFalse(ScreenGeometry.screen(monitor, containsMouse: edge))
        XCTAssertEqual(ScreenGeometry.indicesStartingWithScreen(under: edge, in: [monitor, builtIn]), [1, 0])
    }

    func testReachability() {
        let screens = [builtIn, monitor]
        XCTAssertTrue(ScreenGeometry.isReachable(CGRect(x: 1700, y: 100, width: 400, height: 300), on: screens))
        // Only 30 points poke onto the built-in display.
        XCTAssertFalse(ScreenGeometry.isReachable(CGRect(x: 1770, y: 100, width: 400, height: 300), on: screens))
        // Where an unplugged display used to be.
        XCTAssertFalse(ScreenGeometry.isReachable(CGRect(x: 4000, y: 200, width: 400, height: 300), on: screens))
    }

    func testCentered() {
        XCTAssertEqual(ScreenGeometry.centered(CGSize(width: 400, height: 300), in: monitor),
                       CGRect(x: 577, y: 1964, width: 400, height: 300))
    }
}
