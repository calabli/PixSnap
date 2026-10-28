import PixSnapCore
@testable import PixSnapRender
import XCTest

final class WindowBackdropTests: XCTestCase {
    /// A 100×60 pixel "window": opaque red.
    private func makeWindow() -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return data
    }

    func testNothingToAddLeavesTheWindowAlone() {
        let window = makeWindow()
        XCTAssertTrue(WindowBackdrop.render(window, scale: 2, background: .none, shadow: false) === window)
    }

    func testShadowAloneAddsRoomOnTransparency() throws {
        let result = try XCTUnwrap(WindowBackdrop.render(makeWindow(), scale: 2, background: .none, shadow: true))
        // 44 points of room at 2x on every side.
        XCTAssertEqual(result.width, 100 + 176)
        XCTAssertEqual(result.height, 60 + 176)
        // Clear at the corner, shadowed just under the window, the window itself untouched.
        XCTAssertEqual(pixel(result, 0, 0)[3], 0)
        let under = pixel(result, 88 + 50, 88 + 60 + 20)[3]
        XCTAssertGreaterThan(under, 20)
        XCTAssertLessThan(under, 255)
        XCTAssertEqual(pixel(result, 88 + 50, 88 + 30), [255, 0, 0, 255])
    }

    func testBackgroundAddsPaddingAroundTheCenteredWindow() throws {
        let result = try XCTUnwrap(WindowBackdrop.render(makeWindow(), scale: 2, background: .white, shadow: false))
        // 56 points of padding at 2x on every side.
        XCTAssertEqual(result.width, 100 + 224)
        XCTAssertEqual(result.height, 60 + 224)
        XCTAssertEqual(pixel(result, 5, 5), [247, 247, 247, 255])
        XCTAssertEqual(pixel(result, 112 + 50, 112 + 30), [255, 0, 0, 255])
    }

    func testEveryBackgroundButNoneHasColors() {
        for background in WindowCaptureStyle.Background.allCases {
            XCTAssertEqual(WindowBackdrop.colors(for: background) == nil, background == .none, "\(background)")
        }
    }
}
