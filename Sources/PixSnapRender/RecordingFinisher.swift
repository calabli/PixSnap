import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PixSnapCore

/// 精修's drawing for recordings, one frame at a time with Core Image so playback can show it live:
/// the part of the frame the zoom plan says (see `ZoomPlan`), filling the frame, and around it a
/// background with room, rounded corners and a soft shadow.
public enum RecordingFinisher {
    public struct Style: Equatable, Sendable {
        public var zooms: Bool
        public var zoomScale: Double
        public var hold: Double
        /// Top-left to bottom-right; nil for no background, just the (zoomed) recording.
        public var background: (RGB, RGB)?
        /// Room around the recording, in points.
        public var padding: Double
        public var cornerRadius: Double

        public init(zooms: Bool = true, zoomScale: Double = 2, hold: Double = 1.5, background: (RGB, RGB)? = (RGB(0.56, 0.72, 1), RGB(0.43, 0.42, 0.94)),
                    padding: Double = 48, cornerRadius: Double = 14) {
            self.zooms = zooms
            self.zoomScale = zoomScale
            self.hold = hold
            self.background = background
            self.padding = padding
            self.cornerRadius = cornerRadius
        }

        public static func == (lhs: Style, rhs: Style) -> Bool {
            lhs.zooms == rhs.zooms && lhs.zoomScale == rhs.zoomScale && lhs.hold == rhs.hold && lhs.padding == rhs.padding
                && lhs.cornerRadius == rhs.cornerRadius && lhs.background?.0 == rhs.background?.0 && lhs.background?.1 == rhs.background?.1
        }

        /// The zoom plan for `timeline` in this style (none when zooming is off).
        public func plan(for timeline: RecordingTimeline?) -> ZoomPlan {
            guard zooms, let timeline else { return ZoomPlan(segments: []) }
            return ZoomPlan(clicks: timeline.clicks, scale: zoomScale, hold: hold)
        }
    }

    /// The finished video's size in pixels for a recording `video` pixels across at `scale` pixels
    /// per point: the recording plus the room around it, rounded to even numbers for the encoder.
    public static func outputSize(video: CGSize, scale: CGFloat, style: Style) -> CGSize {
        let pad = style.background == nil ? 0 : (CGFloat(style.padding) * scale).rounded()
        func even(_ value: CGFloat) -> CGFloat { (value / 2).rounded(.up) * 2 }
        return CGSize(width: even(video.width + pad * 2), height: even(video.height + pad * 2))
    }

    /// Frame `source` (its extent at the origin) at `time` seconds, finished in `style`.
    public static func frame(_ source: CIImage, at time: Double, plan: ZoomPlan, scale: CGFloat, style: Style) -> CIImage {
        let width = source.extent.width, height = source.extent.height
        // The zoomed part, from a top-left rect to Core Image's bottom-left one, scaled back up to fill.
        let visible = plan.visibleRect(at: time, width: Double(width), height: Double(height))
        var picture = source
        if visible.width < width - 0.5 {
            let crop = CGRect(x: visible.minX, y: height - visible.maxY, width: visible.width, height: visible.height)
            let zoom = width / visible.width
            picture = source.clampedToExtent().cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: zoom, y: zoom)))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let background = style.background else { return picture }

        let size = outputSize(video: CGSize(width: width, height: height), scale: scale, style: style)
        let canvas = CGRect(origin: .zero, size: size)
        let card = CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - height) / 2).rounded(), width: width, height: height)
        let radius = min(CGFloat(style.cornerRadius) * scale, min(width, height) / 2)

        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: size.height)
        gradient.point1 = CGPoint(x: size.width, y: 0)
        gradient.color0 = CIColor(red: background.0.red, green: background.0.green, blue: background.0.blue)
        gradient.color1 = CIColor(red: background.1.red, green: background.1.green, blue: background.1.blue)
        var output = gradient.outputImage?.cropped(to: canvas) ?? CIImage(color: .white).cropped(to: canvas)

        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = card
        shape.radius = Float(radius)
        shape.color = CIColor(red: 1, green: 1, blue: 1)
        guard let mask = shape.outputImage else { return picture }

        // A soft shadow under the card.
        let shadowShape = CIFilter.roundedRectangleGenerator()
        shadowShape.extent = card.offsetBy(dx: 0, dy: -10 * scale)
        shadowShape.radius = Float(radius)
        shadowShape.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        if let shadow = shadowShape.outputImage {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = shadow
            blur.radius = Float(18 * scale)
            if let soft = blur.outputImage?.cropped(to: canvas) { output = soft.composited(over: output) }
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = picture.transformed(by: CGAffineTransform(translationX: card.minX, y: card.minY))
        blend.backgroundImage = output
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: canvas) ?? output
    }
}
