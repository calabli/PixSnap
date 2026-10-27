import PixSnapCore
@testable import PixSnapRender
import XCTest

@MainActor
final class MagnifierRendererTests: XCTestCase {
    /// 20×10 pixels: white, with the top-left pixel red and the bottom-right pixel blue.
    private func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        // CGContext has a bottom-left origin, so the image's top row is y = 9 here.
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 9, width: 1, height: 1))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 19, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }

    func testPicksColorsWithTopLeftOrigin() {
        let image = makeImage()
        XCTAssertEqual(MagnifierRenderer.color(at: PixelPoint(x: 0, y: 0), in: image), PixelColor(red: 255, green: 0, blue: 0))
        XCTAssertEqual(MagnifierRenderer.color(at: PixelPoint(x: 19, y: 9), in: image), PixelColor(red: 0, green: 0, blue: 255))
        XCTAssertEqual(MagnifierRenderer.color(at: PixelPoint(x: 5, y: 5), in: image), PixelColor(red: 255, green: 255, blue: 255))
        XCTAssertNil(MagnifierRenderer.color(at: PixelPoint(x: 40, y: 5), in: image))
    }

    func testStaysBesideTheCursorInsideTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = MagnifierRenderer.size

        let middle = MagnifierRenderer.origin(forCursor: CGPoint(x: 500, y: 400), in: screen)
        XCTAssertGreaterThan(middle.x, 500)
        XCTAssertLessThan(middle.y + size.height, 400)

        // Bottom-right corner: flips to the left of and above the cursor.
        let corner = MagnifierRenderer.origin(forCursor: CGPoint(x: 990, y: 10), in: screen)
        XCTAssertLessThan(corner.x + size.width, 990)
        XCTAssertGreaterThan(corner.y, 10)
        XCTAssertTrue(screen.contains(CGRect(origin: corner, size: size)))
    }

    /// PIXSNAP_RENDER_INPUT=<png> PIXSNAP_MAGNIFIER_OUTPUT=<png> swift test --filter testWritesVisualSample
    func testWritesVisualSample() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["PIXSNAP_RENDER_INPUT"], let outputPath = environment["PIXSNAP_MAGNIFIER_OUTPUT"] else {
            throw XCTSkip("Set PIXSNAP_RENDER_INPUT and PIXSNAP_MAGNIFIER_OUTPUT to write a visual sample.")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // Draw at 2x, like a Retina screen, with the cursor on the left edge of the sample's blue button.
        let scale: CGFloat = 2
        let size = MagnifierRenderer.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        MagnifierRenderer.draw(image: image, pixel: PixelPoint(x: 560, y: 816), at: .zero, in: context)

        let output = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, output, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
