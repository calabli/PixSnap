import PixSnapCore
@testable import PixSnapRender
import XCTest

final class TranslationOverlayTests: XCTestCase {
    /// A light blue picture with a dark red bar (the "text") across the middle.
    private func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        context.setFillColor(red: 0.6, green: 0.05, blue: 0.05, alpha: 1)
        for x in stride(from: 50, to: 350, by: 12) { context.fill(CGRect(x: x, y: 90, width: 6, height: 20)) }
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func testFindsTheBackgroundAndTextColors() {
        let image = makeImage()
        var data = pixels(image)
        data.withUnsafeBufferPointer { buffer in
            let pixels = TranslationOverlay.Pixels(data: buffer, width: 400, height: 200)
            let rect = CGRect(x: 44, y: 84, width: 312, height: 32)
            let background = pixels.mostCommon(inRingAround: rect)
            XCTAssertEqual(background.blue, 1, accuracy: 0.02)
            XCTAssertEqual(background.red, 0.85, accuracy: 0.02)
            let text = pixels.textColor(in: rect, background: background)
            XCTAssertEqual(text.red, 0.6, accuracy: 0.05)
            XCTAssertLessThan(text.blue, 0.1)
        }
        _ = data
    }

    func testPaintsOverTheOriginalAndWritesTheTranslation() throws {
        let image = makeImage()
        let block = TranslationOverlay.Block(box: CGRect(x: 0.125, y: 0.45, width: 0.75, height: 0.1), lineHeight: 0.1, text: "截图翻译")
        let result = try XCTUnwrap(TranslationOverlay.render(image, blocks: [block]))
        XCTAssertEqual(result.width, 400)
        let data = pixels(result)
        // Somewhere in the box the original bars are gone; some red letters are written instead.
        var background = 0, red = 0
        for y in 88 ..< 112 {
            for x in 50 ..< 350 {
                let i = (y * 400 + x) * 4
                if data[i + 2] > 240, data[i] > 200 { background += 1 }
                if data[i] > 100, data[i + 2] < 60 { red += 1 }
            }
        }
        XCTAssertGreaterThan(background, 24 * 300 * 7 / 10)
        XCTAssertGreaterThan(red, 20)
        // Outside the box nothing changes.
        XCTAssertEqual(Array(data[0 ..< 4]), Array(pixels(image)[0 ..< 4]))
    }
}
