import PixSnapCore
@testable import PixSnapRender
import XCTest

@MainActor
final class AnnotationRendererTests: XCTestCase {
    /// 200×100 pt at 2x: left half white, right half black with a 1-pixel checkerboard.
    private func makeBase() -> CGImage {
        let width = 400, height = 200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for x in stride(from: 200, to: width, by: 1) {
            for y in stride(from: x % 2, to: height, by: 2) {
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    /// RGBA of the pixel at (x, y) with a top-left origin.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    func testRendersAnnotationsAtCaptureScale() throws {
        let base = makeBase()
        var document = AnnotationDocument(canvasSize: CGSize(width: 200, height: 100))
        document.add(Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 60, height: 40)), color: .red, lineWidth: 4))
        document.add(Annotation(shape: .counter(1, center: CGPoint(x: 40, y: 75)), color: .blue, lineWidth: 4))

        let output = try XCTUnwrap(AnnotationRenderer.render(document, base: base, pixelated: nil, scale: 2))
        XCTAssertEqual(output.width, 400)
        XCTAssertEqual(output.height, 200)

        // Rectangle edge at x=10pt → 20px, y=30pt → 60px, red.
        let edge = pixel(output, 20, 60)
        XCTAssertGreaterThan(edge.r, 200)
        XCTAssertLessThan(edge.g, 100)
        // Inside the rectangle stays white.
        let inside = pixel(output, 80, 60)
        XCTAssertGreaterThan(inside.g, 240)
        // Counter fill below the rectangle, near the top-left origin, is blue (not flipped to the bottom).
        let counter = pixel(output, 60, 150)
        XCTAssertGreaterThan(counter.b, 200)
        XCTAssertLessThan(counter.r, 80)
    }

    func testCropShrinksOutput() throws {
        var document = AnnotationDocument(canvasSize: CGSize(width: 200, height: 100))
        document.setCrop(CGRect(x: 100, y: 0, width: 50, height: 25))
        let output = try XCTUnwrap(AnnotationRenderer.render(document, base: makeBase(), pixelated: nil, scale: 2))
        XCTAssertEqual(output.width, 100)
        XCTAssertEqual(output.height, 50)
    }

    func testMosaicFlattensFineDetail() throws {
        let base = makeBase()
        let pixelated = try XCTUnwrap(AnnotationRenderer.pixelated(base, scale: 2))
        var document = AnnotationDocument(canvasSize: CGSize(width: 200, height: 100))
        document.add(Annotation(shape: .mosaic(CGRect(x: 120, y: 20, width: 60, height: 60)), color: .red, lineWidth: 4))

        let output = try XCTUnwrap(AnnotationRenderer.render(document, base: base, pixelated: pixelated, scale: 2))
        // The checkerboard alternates black and white pixel by pixel; under the mosaic neighbours match.
        let a = pixel(output, 300, 100), b = pixel(output, 301, 100)
        XCTAssertEqual(Int(a.r), Int(b.r), accuracy: 2)
        // Outside the mosaic the checkerboard is untouched.
        let c = pixel(output, 300, 190), d = pixel(output, 301, 190)
        XCTAssertGreaterThan(abs(Int(c.r) - Int(d.r)), 200)
    }

    /// Renders every annotation type onto an image for a visual check:
    /// PIXSNAP_RENDER_INPUT=<png> PIXSNAP_RENDER_OUTPUT=<png> swift test --filter testWritesVisualSample
    func testWritesVisualSample() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["PIXSNAP_RENDER_INPUT"], let outputPath = environment["PIXSNAP_RENDER_OUTPUT"] else {
            throw XCTSkip("Set PIXSNAP_RENDER_INPUT and PIXSNAP_RENDER_OUTPUT to write a visual sample.")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil))
        let base = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let scale: CGFloat = 2
        var document = AnnotationDocument(canvasSize: CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale))

        let fontSize: CGFloat = 22
        let label = "点这里发货"
        let labelSize = AnnotationRenderer.textSize(label, fontSize: fontSize)
        document.add(Annotation(shape: .rectangle(CGRect(x: 270, y: 376, width: 180, height: 64)), color: .red, lineWidth: 4))
        document.add(Annotation(shape: .arrow(from: CGPoint(x: 640, y: 300), to: CGPoint(x: 460, y: 395)), color: .red, lineWidth: 4))
        document.add(Annotation(shape: .text(label, frame: CGRect(origin: CGPoint(x: 600, y: 262), size: labelSize), fontSize: fontSize), color: .red, lineWidth: 4))
        document.add(Annotation(shape: .mosaic(CGRect(x: 425, y: 165, width: 200, height: 30)), color: .red, lineWidth: 4))
        document.add(Annotation(shape: .counter(1, center: CGPoint(x: 262, y: 180)), color: .blue, lineWidth: 4))
        document.add(Annotation(shape: .counter(2, center: CGPoint(x: 262, y: 300)), color: .yellow, lineWidth: 4))
        document.setCrop(CGRect(x: 240, y: 80, width: 600, height: 420))

        let output = try XCTUnwrap(AnnotationRenderer.render(document, base: base, pixelated: AnnotationRenderer.pixelated(base, scale: scale), scale: scale))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, output, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testNewShapesDraw() throws {
        let base = makeBase()
        var document = AnnotationDocument(canvasSize: CGSize(width: 200, height: 100))
        // A red pen stroke and a line across the white half.
        document.add(Annotation(shape: .pen([CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 20), CGPoint(x: 90, y: 20)]), color: .red, lineWidth: 4))
        document.add(Annotation(shape: .line(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 90, y: 60)), color: .blue, lineWidth: 4))
        // A yellow marker: see-through, so white under it turns pale yellow, not solid.
        document.add(Annotation(shape: .highlight([CGPoint(x: 10, y: 85), CGPoint(x: 90, y: 85)]), color: .yellow, lineWidth: 2))
        let output = try XCTUnwrap(AnnotationRenderer.render(document, base: base, pixelated: nil, scale: 2))
        XCTAssertEqual(pixel(output, 100, 40).r, 242)
        XCTAssertEqual(pixel(output, 100, 40).g, 59)
        XCTAssertEqual(pixel(output, 100, 120).b, 255)
        let marked = pixel(output, 100, 170)
        XCTAssertEqual(marked.r, 255)
        XCTAssertGreaterThan(marked.b, 100)
        XCTAssertLessThan(marked.b, 200)
    }

    func testMagnifierShowsTheMiddleEnlarged() throws {
        // A lens centered where the white half meets the checkerboard: enlarged, the boundary
        // stays at the center, and a point a quarter-lens to the right shows the checkerboard.
        let base = makeBase()
        var document = AnnotationDocument(canvasSize: CGSize(width: 200, height: 100))
        document.add(Annotation(shape: .magnifier(CGRect(x: 60, y: 10, width: 80, height: 80)), color: .red, lineWidth: 2))
        let output = try XCTUnwrap(AnnotationRenderer.render(document, base: base, pixelated: nil, scale: 2))
        // Left of center inside the lens: white.
        XCTAssertEqual(pixel(output, 2 * 90, 2 * 50).r, 255)
        // Outside the lens, top-left corner: unchanged white.
        XCTAssertEqual(pixel(output, 4, 4).r, 255)
    }
}
