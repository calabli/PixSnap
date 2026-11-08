import CoreImage
import PixSnapCore
@testable import PixSnapRender
import XCTest

final class RecordingFinisherTests: XCTestCase {
    /// 400 × 200: white, with a red 40 × 40 square in the top-left corner.
    private func source() -> CIImage {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 160, width: 40, height: 40))
        return red.composited(over: white)
    }

    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> (UInt8, UInt8, UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &data, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (data[0], data[1], data[2])
    }

    func testOutputSizeAddsEvenRoom() {
        let style = RecordingFinisher.Style(padding: 25)
        XCTAssertEqual(RecordingFinisher.outputSize(video: CGSize(width: 801, height: 600), scale: 2, style: style), CGSize(width: 902, height: 700))
        var bare = style
        bare.background = nil
        XCTAssertEqual(RecordingFinisher.outputSize(video: CGSize(width: 800, height: 600), scale: 2, style: bare), CGSize(width: 800, height: 600))
    }

    func testZoomFillsTheFrameWithTheClickedCorner() {
        var style = RecordingFinisher.Style()
        style.background = nil
        let plan = ZoomPlan(clicks: [RecordingTimeline.Click(t: 1, x: 0, y: 0)], scale: 2, hold: 1)
        // Not zoomed yet: the square is 40 px, so (60, 180) is white.
        let before = RecordingFinisher.frame(source(), at: 0, plan: plan, scale: 1, style: style)
        XCTAssertEqual(pixel(before, 60, 180).1, 255)
        // Zoomed 2× on the top-left: the square is 80 px now, so (60, 180) is red.
        let zoomed = RecordingFinisher.frame(source(), at: 1, plan: plan, scale: 1, style: style)
        XCTAssertEqual(zoomed.extent, CGRect(x: 0, y: 0, width: 400, height: 200))
        let red = pixel(zoomed, 60, 180)
        XCTAssertGreaterThan(red.0, 200)
        XCTAssertLessThan(red.1, 60)
    }

    func testBackgroundSurroundsTheRecording() {
        let style = RecordingFinisher.Style(zooms: false, padding: 20, cornerRadius: 0)
        let framed = RecordingFinisher.frame(source(), at: 0, plan: ZoomPlan(segments: []), scale: 1, style: style)
        XCTAssertEqual(framed.extent.size, CGSize(width: 440, height: 240))
        // A corner of the room is the gradient (blue-ish), the middle is the recording (white).
        let corner = pixel(framed, 4, 236)
        XCTAssertGreaterThan(corner.2, corner.0)
        XCTAssertEqual(pixel(framed, 220, 120).0, 255)
    }
}
