import XCTest
@testable import PixSnapCore

final class RecordingTimelineTests: XCTestCase {
    private func click(_ t: Double, _ x: Double, _ y: Double) -> RecordingTimeline.Click {
        RecordingTimeline.Click(t: t, x: x, y: y)
    }

    func testCloseClicksShareOneZoomAndFarOnesDont() {
        let plan = ZoomPlan(clicks: [click(2, 0.2, 0.3), click(3, 0.6, 0.4), click(12, 0.8, 0.8)], scale: 2, hold: 1.5)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].focus.count, 2)
        XCTAssertEqual(plan.segments[0].start, 2 - ZoomPlan.lead - ZoomPlan.transition, accuracy: 1e-9)
        XCTAssertEqual(plan.segments[0].end, 3 + 1.5 + ZoomPlan.transition, accuracy: 1e-9)
    }

    func testZoomsInByTheClickAndBackOutAfter() {
        let plan = ZoomPlan(clicks: [click(5, 0.25, 0.75)], scale: 2, hold: 1.5)
        XCTAssertEqual(plan.state(at: 0).scale, 1)
        let at = plan.state(at: 5)
        XCTAssertEqual(at.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(at.centerX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(at.centerY, 0.75, accuracy: 1e-9)
        // Halfway out, it's halfway between.
        let outMiddle = plan.segments[0].end - ZoomPlan.transition / 2
        XCTAssertEqual(plan.state(at: outMiddle).scale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(plan.state(at: 20).scale, 1)
    }

    func testGlidesFromOneClickToTheNext() {
        let plan = ZoomPlan(clicks: [click(2, 0.2, 0.5), click(4, 0.8, 0.5)], scale: 2, hold: 1)
        XCTAssertEqual(plan.state(at: 3).centerX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(plan.state(at: 3.75).centerX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(plan.state(at: 4).centerX, 0.8, accuracy: 1e-9)
    }

    func testVisibleRectStaysInsideTheFrame() {
        let plan = ZoomPlan(clicks: [click(1, 0.98, 0.02)], scale: 2, hold: 1)
        let rect = plan.visibleRect(at: 1, width: 1000, height: 600)
        XCTAssertEqual(rect, CGRect(x: 500, y: 0, width: 500, height: 300))
        XCTAssertEqual(plan.visibleRect(at: 30, width: 1000, height: 600), CGRect(x: 0, y: 0, width: 1000, height: 600))
    }

    func testTrimShiftsAndDropsEvents() {
        var timeline = RecordingTimeline(width: 800, height: 600)
        timeline.clicks = [click(1, 0.1, 0.1), click(5, 0.5, 0.5), click(9, 0.9, 0.9)]
        timeline.keys = [.init(t: 6, label: "⌘F")]
        timeline.marks = [2, 7]
        let cut = timeline.trimmed(from: 4, to: 8)
        XCTAssertEqual(cut.clicks.map(\.t), [1])
        XCTAssertEqual(cut.keys.map(\.t), [2])
        XCTAssertEqual(cut.marks, [3])
    }

    func testRoundTripsThroughJSON() throws {
        var timeline = RecordingTimeline(width: 800, height: 600)
        timeline.moves = [.init(t: 0.1, x: 0.5, y: 0.5)]
        timeline.clicks = [.init(t: 1, x: 0.2, y: 0.3, button: .right, count: 2, element: "隐私与安全性", app: "系统设置")]
        let decoded = try JSONDecoder().decode(RecordingTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(decoded, timeline)
    }
}
