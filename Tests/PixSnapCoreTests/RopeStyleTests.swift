import XCTest
@testable import PixSnapCore

final class RopeStyleTests: XCTestCase {
    func testParsesHexColors() {
        XCTAssertEqual(PixelColor(hex: "#3A7BD5"), PixelColor(red: 58, green: 123, blue: 213))
        XCTAssertEqual(PixelColor(hex: "3a7bd5"), PixelColor(red: 58, green: 123, blue: 213))
        XCTAssertNil(PixelColor(hex: "#3A7BD"))
        XCTAssertNil(PixelColor(hex: "#GGGGGG"))
    }

    func testRoundTripsThroughJSON() throws {
        let style = RopeStyle(thickness: .thick, color: PixelColor(red: 214, green: 58, blue: 52), material: .jute)
        let data = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(RopeStyle.self, from: data), style)
    }

    func testFallsBackFieldByField() throws {
        let data = Data(##"{"thickness":"huge","color":"#123456","material":"silk"}"##.utf8)
        let style = try JSONDecoder().decode(RopeStyle.self, from: data)
        XCTAssertEqual(style.thickness, RopeStyle.default.thickness)
        XCTAssertEqual(style.color, PixelColor(red: 0x12, green: 0x34, blue: 0x56))
        XCTAssertEqual(style.material, RopeStyle.default.material)
    }

    func testThicknessGrows() {
        let widths = RopeStyle.Thickness.allCases.map(\.width)
        XCTAssertEqual(widths, widths.sorted())
    }
}
