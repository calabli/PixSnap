import PixSnapCore
@testable import PixSnapRender
import XCTest

final class BeautifierTests: XCTestCase {
    private func makeImage(width: Int = 400, height: Int = 300, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Top-left origin.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return data
    }

    func testMeasuresAFlatDarkImage() {
        let measured = Beautifier.measure(makeImage(red: 0.1, green: 0.1, blue: 0.12))
        XCTAssertLessThan(measured.brightness, 0.2)
        XCTAssertGreaterThan(measured.flatness, 0.99)
        XCTAssertGreaterThan(measured.concentration, 0.99)
    }

    func testRoomAroundOnABackground() throws {
        let style = BeautifyStyle(name: "t", background: .gradient(RGB(1, 1, 1), RGB(1, 1, 1)), padding: 0.1, cornerRadius: 10,
                                  shadow: .none, frame: .none)
        let result = try XCTUnwrap(Beautifier.render(makeImage(red: 1, green: 0, blue: 0), scale: 2, style: style))
        // 150 × 0.1 = 15 points, under the 28-point minimum: 56 pixels each side.
        XCTAssertEqual(result.width, 400 + 112)
        XCTAssertEqual(result.height, 300 + 112)
        XCTAssertEqual(pixel(result, 2, 2), [255, 255, 255, 255])
        XCTAssertEqual(pixel(result, 256, 206), [255, 0, 0, 255])
        // The corner is rounded off, showing the background.
        XCTAssertEqual(pixel(result, 57, 57), [255, 255, 255, 255])
    }

    func testWindowFrameAddsATitleBarWithButtons() throws {
        let style = BeautifyStyle(name: "t", background: .gradient(RGB(0, 0, 0), RGB(0, 0, 0)), padding: 0.1, cornerRadius: 0,
                                  shadow: .none, frame: .window(dark: true))
        let result = try XCTUnwrap(Beautifier.render(makeImage(red: 0, green: 0, blue: 1), scale: 2, style: style))
        XCTAssertEqual(result.height, 300 + 56 + 112)
        // The red button: 14 points in, centered on the 28-point bar.
        let red = pixel(result, 56 + 28 + 12, 56 + 28)
        XCTAssertGreaterThan(red[0], 200)
        XCTAssertLessThan(red[2], 120)
        XCTAssertEqual(pixel(result, 256, 56 + 56 + 150), [0, 0, 255, 255])
    }

    func testBlurredBackgroundTakesTheImagesColors() throws {
        let style = BeautifyStyle(name: "t", background: .blurredImage, padding: 0.1, cornerRadius: 10, shadow: .soft, frame: .none)
        let result = try XCTUnwrap(Beautifier.render(makeImage(red: 0, green: 0.8, blue: 0), scale: 1, style: style))
        let corner = pixel(result, 3, 3)
        XCTAssertGreaterThan(corner[1], 150)
        XCTAssertLessThan(corner[0], 60)
    }
}
