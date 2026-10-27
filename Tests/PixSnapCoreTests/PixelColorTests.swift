import XCTest
@testable import PixSnapCore

final class PixelColorTests: XCTestCase {
    func testFormatsHexAndRGB() {
        let color = PixelColor(red: 58, green: 123, blue: 213)
        XCTAssertEqual(color.hex, "#3A7BD5")
        XCTAssertEqual(color.rgb, "58, 123, 213")
        XCTAssertEqual(PixelColor(red: 0, green: 5, blue: 255).hex, "#0005FF")
    }

    func testPixelPointFlipsAndScales() {
        let view = CGSize(width: 1000, height: 800)
        let image = CGSize(width: 2000, height: 1600)
        // Top-left corner of the view is pixel (0, 0).
        XCTAssertEqual(SelectionGeometry.pixelPoint(forViewPoint: CGPoint(x: 0, y: 799.9), viewSize: view, imageSize: image),
                       PixelPoint(x: 0, y: 0))
        // Half-point steps land on different Retina pixels.
        XCTAssertEqual(SelectionGeometry.pixelPoint(forViewPoint: CGPoint(x: 10.5, y: 700), viewSize: view, imageSize: image),
                       PixelPoint(x: 21, y: 200))
    }

    func testPixelPointClampsToImage() {
        let view = CGSize(width: 100, height: 100)
        let image = CGSize(width: 200, height: 200)
        XCTAssertEqual(SelectionGeometry.pixelPoint(forViewPoint: CGPoint(x: 100, y: 0), viewSize: view, imageSize: image),
                       PixelPoint(x: 199, y: 199))
        XCTAssertEqual(SelectionGeometry.pixelPoint(forViewPoint: CGPoint(x: -5, y: 150), viewSize: view, imageSize: image),
                       PixelPoint(x: 0, y: 0))
    }
}
