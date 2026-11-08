import XCTest
@testable import PixSnapCore

final class VideoEditTests: XCTestCase {
    func testCutAndSpeedUpChangeTheLength() {
        var edit = VideoEdit()
        edit.apply(.init(start: 2, end: 4, speed: 0))
        edit.apply(.init(start: 6, end: 10, speed: 4))
        XCTAssertEqual(edit.editedDuration(of: 12), 12 - 2 - 3, accuracy: 1e-9)
        XCTAssertEqual(edit.pieces(duration: 12).map(\.speed), [1, 0, 1, 4, 1])
    }

    func testTimesMapBothWays() {
        let edit = VideoEdit(changes: [.init(start: 2, end: 4, speed: 0), .init(start: 6, end: 10, speed: 4)])
        XCTAssertEqual(edit.editedTime(1, duration: 12), 1)
        XCTAssertNil(edit.editedTime(3, duration: 12))
        XCTAssertEqual(edit.editedTime(5, duration: 12), 3)
        XCTAssertEqual(edit.editedTime(8, duration: 12) ?? -1, 4.5, accuracy: 1e-9)
        XCTAssertEqual(edit.editedTime(11, duration: 12) ?? -1, 6, accuracy: 1e-9)
        XCTAssertEqual(edit.originalTime(4.5, duration: 12), 8, accuracy: 1e-9)
        XCTAssertEqual(edit.originalTime(3, duration: 12), 5, accuracy: 1e-9)
    }

    func testNewChangesReplaceAndClearSplits() {
        var edit = VideoEdit(changes: [.init(start: 2, end: 8, speed: 4)])
        edit.apply(.init(start: 4, end: 5, speed: 0))
        XCTAssertEqual(edit.changes.map { [$0.start, $0.end, $0.speed] }, [[2, 4, 4], [4, 5, 0], [5, 8, 4]])
        edit.clear(from: 3, to: 7)
        XCTAssertEqual(edit.changes.map { [$0.start, $0.end] }, [[2, 3], [7, 8]])
        // Too short to mean anything.
        edit.apply(.init(start: 9, end: 9.05, speed: 0))
        XCTAssertEqual(edit.changes.count, 2)
    }

    func testTimelineFollowsTheEdit() {
        var timeline = RecordingTimeline(width: 100, height: 100)
        timeline.clicks = [.init(t: 1, x: 0, y: 0), .init(t: 3, x: 0, y: 0), .init(t: 8, x: 0, y: 0)]
        timeline.marks = [5]
        let edit = VideoEdit(changes: [.init(start: 2, end: 4, speed: 0), .init(start: 6, end: 10, speed: 4)])
        let edited = timeline.edited(by: edit, duration: 12)
        XCTAssertEqual(edited.clicks.map(\.t), [1, 4.5])
        XCTAssertEqual(edited.marks, [3])
    }
}
