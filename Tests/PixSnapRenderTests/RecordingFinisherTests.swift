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

    func testClickRippleAndKeyCaptionAreDrawn() {
        var style = RecordingFinisher.Style(zooms: false)
        style.background = nil
        style.pointerHalo = false
        var timeline = RecordingTimeline(width: 400, height: 200)
        timeline.clicks = [RecordingTimeline.Click(t: 1, x: 0.75, y: 0.5)]
        timeline.keys = [RecordingTimeline.Key(t: 1, label: "⌘F")]
        let plain = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let frame = RecordingFinisher.frame(plain, at: 1.05, plan: ZoomPlan(segments: []), scale: 1, style: style, timeline: timeline)
        // Somewhere along the line right of the click at (300, 100), the ring: blue, not white.
        let ring = (0 ..< 40).map { pixel(frame, 300 + CGFloat($0), 100) }.first { Int($0.2) - Int($0.0) > 60 }
        XCTAssertNotNil(ring)
        // The caption's dark pill near the bottom middle.
        let caption = pixel(frame, 200, 40)
        XCTAssertLessThan(caption.0, 150)
        // Long after, nothing is drawn.
        let later = RecordingFinisher.frame(plain, at: 5, plan: ZoomPlan(segments: []), scale: 1, style: style, timeline: timeline)
        XCTAssertEqual(pixel(later, 200, 40).0, 255)
    }

    func testMosaicBlursOnlyItsBoxAndOnlyWhileShowing() {
        var style = RecordingFinisher.Style(zooms: false)
        style.background = nil
        // Over the red square's edge (it's 40 px; the box is 80).
        let region = MosaicRegion(x: 0, y: 0, width: 0.2, height: 0.4, start: 1, end: 2)
        let plain = RecordingFinisher.frame(source(), at: 0.5, plan: ZoomPlan(segments: []), scale: 1, style: style, mosaics: [region])
        XCTAssertEqual(pixel(plain, 41, 158).1, 255)
        let covered = RecordingFinisher.frame(source(), at: 1.5, plan: ZoomPlan(segments: []), scale: 1, style: style, mosaics: [region])
        // Blocks are 14 px centred on 0, so the one from 35 to 49 straddles the square's edge at 40 and
        // takes one colour: (36, 190) was red and isn't any more, like (46, 190).
        XCTAssertLessThan(pixel(source(), 36, 190).1, 60)
        XCTAssertEqual(pixel(covered, 36, 190).1, pixel(covered, 46, 190).1)
        // Outside the box nothing changes.
        XCTAssertEqual(pixel(covered, 300, 100).1, 255)
    }

    func testPlacementRoundTrips() {
        let style = RecordingFinisher.Style(padding: 20)
        let plan = ZoomPlan(clicks: [RecordingTimeline.Click(t: 1, x: 0.25, y: 0.25)], scale: 2, hold: 1)
        let placement = RecordingFinisher.Placement(video: CGSize(width: 400, height: 200), scale: 1, style: style, plan: plan, time: 1)
        let point = placement.output(x: 0.3, y: 0.4)
        let back = placement.source(point)
        XCTAssertEqual(back.x, 0.3, accuracy: 1e-6)
        XCTAssertEqual(back.y, 0.4, accuracy: 1e-6)
        // No zoom: the recording's corner is at the card's corner.
        let flat = RecordingFinisher.Placement(video: CGSize(width: 400, height: 200), scale: 1, style: style, plan: ZoomPlan(segments: []), time: 0)
        XCTAssertEqual(flat.output(x: 0, y: 0), CGPoint(x: 20, y: 20))
    }
}
