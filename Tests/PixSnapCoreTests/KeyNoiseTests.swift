import XCTest
@testable import PixSnapCore

final class KeyNoiseTests: XCTestCase {
    func testTypingRunsJoinAndLoneKeysStayShort() {
        let ranges = KeyNoise.quietRanges(typing: [1.0, 1.15, 1.3, 5.0], duration: 10)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 0.97, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].upperBound, 1.42, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].lowerBound, 4.97, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].upperBound, 5.12, accuracy: 1e-9)
    }

    func testStaysInsideTheVideo() {
        let ranges = KeyNoise.quietRanges(typing: [0.01, 9.95, 12], duration: 10)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 10)
        XCTAssertEqual(ranges.count, 2)
    }

    func testOldTimelinesReadWithoutTyping() throws {
        let json = #"{"width":100,"height":50,"moves":[],"clicks":[],"keys":[],"marks":[1]}"#
        let timeline = try JSONDecoder().decode(RecordingTimeline.self, from: Data(json.utf8))
        XCTAssertEqual(timeline.typing, [])
        XCTAssertEqual(timeline.marks, [1])
        var typed = timeline
        typed.typing = [2, 3]
        XCTAssertEqual(try JSONDecoder().decode(RecordingTimeline.self, from: JSONEncoder().encode(typed)), typed)
        XCTAssertEqual(typed.trimmed(from: 2.5, to: 4).typing, [0.5])
    }
}
