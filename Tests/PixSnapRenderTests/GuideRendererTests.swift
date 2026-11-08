import CoreGraphics
@testable import PixSnapRender
import XCTest

@MainActor
final class GuideRendererTests: XCTestCase {
    private func white(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top-left coordinates, as the step positions are.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    func testClickSpotStaysBrightAndTheRestIsDimmed() throws {
        let image = try XCTUnwrap(GuideRenderer.annotate(white(400, 300), number: 2, x: 0.25, y: 0.5, radius: 30))
        XCTAssertEqual(pixel(image, 100, 150).0, 255)
        XCTAssertLessThan(pixel(image, 380, 20).0, 200)
        // The ring, blue, at the spot's edge.
        let ring = pixel(image, 130, 150)
        XCTAssertGreaterThan(Int(ring.2) - Int(ring.0), 80)
    }

    func testLongImageStacksEverySteps() throws {
        let steps = [(title: "点击“隐私与安全性”", image: white(800, 400)), (title: "按 ⌘ Command + F", image: white(800, 400))]
        let image = try XCTUnwrap(GuideRenderer.longImage(title: "如何打开权限", steps: steps, width: 1000))
        XCTAssertEqual(image.width, 1000)
        // Two pictures scaled to 888 wide (1000 less the margins) are 444 tall each, plus the text.
        XCTAssertGreaterThan(image.height, 444 * 2 + 150)
    }
}
