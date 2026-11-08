import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PixSnapCore

/// 精修's drawing for recordings, one frame at a time with Core Image so playback can show it live:
/// the part of the frame the zoom plan says (see `ZoomPlan`), filling the frame, and around it a
/// background with room, rounded corners and a soft shadow. Over the recording, from its timeline:
/// a ripple at each click (blue, orange for the right button, two rings for a double-click), a soft
/// halo following the pointer, and the shortcut pressed, spelled out, along the bottom.
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
        public var clickEffects: Bool = true
        public var pointerHalo: Bool = true
        public var showsKeys: Bool = true

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
                && lhs.clickEffects == rhs.clickEffects && lhs.pointerHalo == rhs.pointerHalo && lhs.showsKeys == rhs.showsKeys
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

    /// Frame `source` (its extent at the origin) at `time` seconds, finished in `style`, with the
    /// clicks, pointer and keys from `timeline` drawn over it.
    public static func frame(_ source: CIImage, at time: Double, plan: ZoomPlan, scale: CGFloat, style: Style,
                             timeline: RecordingTimeline? = nil) -> CIImage {
        let width = source.extent.width, height = source.extent.height
        // The zoomed part, from a top-left rect to Core Image's bottom-left one, scaled back up to fill.
        let visible = plan.visibleRect(at: time, width: Double(width), height: Double(height))
        let crop = CGRect(x: visible.minX, y: height - visible.maxY, width: visible.width, height: visible.height)
        let zoom = width / max(visible.width, 1)
        var picture = source
        if visible.width < width - 0.5 {
            picture = source.clampedToExtent().cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: zoom, y: zoom)))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let timeline {
            // A spot in the recording (fractions, top-left origin) to where it is in the zoomed picture.
            let place = { (x: Double, y: Double) -> CGPoint in
                CGPoint(x: (CGFloat(x) * width - crop.minX) * zoom, y: ((1 - CGFloat(y)) * height - crop.minY) * zoom)
            }
            picture = overlays(on: picture, at: time, timeline: timeline, place: place, scale: scale, style: style)
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

    // MARK: Over the recording

    /// How long a click's ripple lasts, and a shortcut's caption stays.
    static let rippleDuration = 0.55
    static let keyDuration = 1.4

    private static func overlays(on picture: CIImage, at time: Double, timeline: RecordingTimeline,
                                 place: (Double, Double) -> CGPoint, scale: CGFloat, style: Style) -> CIImage {
        var output = picture
        let bounds = picture.extent
        if style.pointerHalo, let pointer = timeline.pointer(at: time), let halo = haloImage {
            let size = 64 * scale
            let center = place(pointer.x, pointer.y)
            let image = CIImage(cgImage: halo)
                .transformed(by: CGAffineTransform(scaleX: size / CGFloat(halo.width), y: size / CGFloat(halo.height)))
                .transformed(by: CGAffineTransform(translationX: center.x - size / 2, y: center.y - size / 2))
            output = image.composited(over: output)
        }
        if style.clickEffects, let ring = ringImage {
            for click in timeline.clicks where time >= click.t && time - click.t < rippleDuration {
                let progress = CGFloat((time - click.t) / rippleDuration)
                let color: CIVector = click.button == .right ? CIVector(x: 1, y: 0.62, z: 0.04, w: 1) : CIVector(x: 0.04, y: 0.52, z: 1, w: 1)
                let center = place(click.x, click.y)
                for ringIndex in 0 ..< (click.count >= 2 ? 2 : 1) {
                    let grown = min(1, progress + CGFloat(ringIndex) * 0.25)
                    let size = (26 + 50 * grown) * scale
                    let tint = CIFilter.colorMatrix()
                    tint.inputImage = CIImage(cgImage: ring)
                    tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
                    tint.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
                    tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
                    tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1 - progress)
                    tint.biasVector = CIVector(x: color.x, y: color.y, z: color.z, w: 0)
                    guard let tinted = tint.outputImage else { continue }
                    let ringOnly = tinted
                        .transformed(by: CGAffineTransform(scaleX: size / CGFloat(ring.width), y: size / CGFloat(ring.height)))
                        .transformed(by: CGAffineTransform(translationX: center.x - size / 2, y: center.y - size / 2))
                    output = ringOnly.composited(over: output)
                }
            }
        }
        if style.showsKeys, let key = timeline.keys.last(where: { time >= $0.t && time - $0.t < keyDuration }),
           let caption = keyCaption(Keystroke.spelledOut(key.label), scale: scale) {
            let fade = min(1, CGFloat((keyDuration - (time - key.t)) / 0.3))
            let placed = caption.transformed(by: CGAffineTransform(translationX: bounds.midX - caption.extent.width / 2,
                                                                    y: bounds.minY + 28 * scale))
            let faded = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: fade)])
            output = faded.composited(over: output)
        }
        return output.cropped(to: bounds)
    }

    /// A shortcut's caption: white text on a dark rounded pill.
    private static func keyCaption(_ text: String, scale: CGFloat) -> CIImage? {
        let generator = CIFilter.textImageGenerator()
        generator.text = text
        generator.fontName = "PingFangSC-Semibold"
        generator.fontSize = Float(20 * scale)
        generator.scaleFactor = 1
        guard let black = generator.outputImage else { return nil }
        // The generator draws black text: turned white.
        let white = black.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        let padX = 16 * scale, padY = 9 * scale
        let pill = CGRect(x: 0, y: 0, width: white.extent.width + padX * 2, height: white.extent.height + padY * 2)
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = pill
        shape.radius = Float(pill.height / 2)
        shape.color = CIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0.92)
        guard let background = shape.outputImage else { return nil }
        let text = white.transformed(by: CGAffineTransform(translationX: padX - white.extent.minX, y: padY - white.extent.minY))
        return text.composited(over: background).cropped(to: pill)
    }

    /// A ring, white on clear, tinted per click.
    private static let ringImage: CGImage? = {
        let side = 128
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.3))
        context.fillEllipse(in: CGRect(x: 12, y: 12, width: 104, height: 104))
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(14)
        context.strokeEllipse(in: CGRect(x: 12, y: 12, width: 104, height: 104))
        return context.makeImage()
    }()

    /// A soft yellow glow, brightest in the middle.
    private static let haloImage: CGImage? = {
        let side = 128
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 0.45),
                                                                    CGColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 0)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        let center = CGPoint(x: side / 2, y: side / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(side / 2), options: [])
        return context.makeImage()
    }()
}
