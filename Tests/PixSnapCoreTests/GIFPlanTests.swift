import XCTest
@testable import PixSnapCore

final class GIFPlanTests: XCTestCase {
    func testFramesCoverTheRecordingAtTheChosenRate() {
        let plan = GIFPlan(duration: 2, sourceSize: CGSize(width: 1600, height: 900), fps: 10)
        XCTAssertEqual(plan.times.count, 20)
        XCTAssertEqual(plan.frameDelay, 0.1, accuracy: 0.0001)
        XCTAssertEqual(plan.times.first, 0)
        XCTAssertEqual(plan.times.last ?? 0, 1.9, accuracy: 0.0001)
    }

    func testDelayRoundsToHundredthsAndSizeShrinksToEvenWidth() {
        let plan = GIFPlan(duration: 1, sourceSize: CGSize(width: 1601, height: 901), fps: 15, maxWidth: 800)
        // 1/15 s rounds to 0.07 s, the nearest a GIF can store.
        XCTAssertEqual(plan.frameDelay, 0.07, accuracy: 0.0001)
        XCTAssertEqual(plan.size, CGSize(width: 800, height: 450))
        // Small recordings keep their size.
        XCTAssertEqual(GIFPlan(duration: 1, sourceSize: CGSize(width: 300, height: 200)).size, CGSize(width: 300, height: 200))
    }

    func testVeryShortRecordingStillHasAFrame() {
        XCTAssertEqual(GIFPlan(duration: 0.01, sourceSize: CGSize(width: 100, height: 100)).times, [0])
    }

    func testRecordingSizeIsEvenAndCapped() {
        XCTAssertEqual(recordingPixelSize(points: CGSize(width: 501, height: 301), scale: 2), CGSize(width: 1002, height: 602))
        // A 3360-point-wide screen at 2x would be 6720 pixels; capped to 3840.
        XCTAssertEqual(recordingPixelSize(points: CGSize(width: 3360, height: 1890), scale: 2), CGSize(width: 3840, height: 2160))
    }
}
