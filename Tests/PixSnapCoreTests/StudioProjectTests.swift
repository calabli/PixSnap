import XCTest
@testable import PixSnapCore

final class StudioProjectTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let project = StudioProject(changes: [.init(start: 1, end: 2, speed: 0)], disabledClicks: [3.5],
                                    mosaics: [MosaicRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.1, start: 0, end: 10)])
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(StudioProject.self, from: data), project)
    }

    func testTrimmingShiftsEverything() {
        let project = StudioProject(changes: [.init(start: 1, end: 3, speed: 4), .init(start: 8, end: 9, speed: 0)], disabledClicks: [0.5, 4],
                                    mosaics: [MosaicRegion(x: 0, y: 0, width: 0.1, height: 0.1, start: 0, end: 5)])
        let trimmed = project.trimmed(from: 2, to: 7)
        XCTAssertEqual(trimmed.changes, [.init(start: 0, end: 1, speed: 4)])
        XCTAssertEqual(trimmed.disabledClicks, [2])
        XCTAssertEqual(trimmed.mosaics.map { [$0.start, $0.end] }, [[0, 3]])
    }

    func testMosaicsFollowTheEdit() {
        let project = StudioProject(mosaics: [MosaicRegion(x: 0, y: 0, width: 0.1, height: 0.1, start: 3, end: 8),
                                              MosaicRegion(x: 0, y: 0, width: 0.1, height: 0.1, start: 2.2, end: 3.8)])
        let edit = VideoEdit(changes: [.init(start: 2, end: 4, speed: 0)])
        let moved = project.mosaics(editedBy: edit, duration: 10)
        // Starts inside the cut: from where the cut was. The one wholly inside the cut is gone.
        XCTAssertEqual(moved.map { [$0.start, $0.end] }, [[2, 6]])
    }

    func testClampingKeepsTheBoxInside() {
        let region = MosaicRegion(x: 0.95, y: -0.1, width: 0.2, height: 0.001, start: 0, end: 1).clamped()
        XCTAssertEqual(region.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(region.y, 0)
        XCTAssertEqual(region.height, 0.01)
    }
}
