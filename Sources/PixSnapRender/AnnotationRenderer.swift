import AppKit
import CoreImage.CIFilterBuiltins
import PixSnapCore

/// Draws an annotation document with Core Graphics. The same code paints the editor canvas and the
/// exported image, so what you see is exactly what gets copied or saved.
@MainActor
public enum AnnotationRenderer {
    /// A pixelated copy of the screenshot; mosaic annotations reveal it through their rect.
    public static func pixelated(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(8, 9 * scale))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    /// A blurred copy of the screenshot; blur annotations reveal it through their rect.
    public static func blurred(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(10 * scale)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    /// Draws into a context whose user space is canvas points with a top-left origin.
    public static func draw(
        _ document: AnnotationDocument,
        base: CGImage,
        pixelated: CGImage?,
        blurred: CGImage? = nil,
        in context: CGContext,
        hiding hiddenID: Annotation.ID? = nil
    ) {
        drawImage(base, in: document.canvasRect, context: context)
        let effects = Effects(base: base, pixelated: pixelated, blurred: blurred, canvas: document.canvasRect)
        for annotation in document.annotations where annotation.id != hiddenID {
            draw(annotation, effects: effects, in: context)
        }
    }

    /// The screenshot and its pixelated and blurred copies, for the shapes that show them.
    private struct Effects {
        let base: CGImage
        let pixelated: CGImage?
        let blurred: CGImage?
        let canvas: CGRect
    }

    /// Renders the cropped, annotated result at the capture's pixel scale.
    public static func render(_ document: AnnotationDocument, base: CGImage, pixelated: CGImage?, blurred: CGImage? = nil,
                              scale: CGFloat) -> CGImage? {
        let output = document.outputRect
        let width = Int((output.width * scale).rounded())
        let height = Int((output.height * scale).rounded())
        let colorSpace = base.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -output.minX, y: -output.minY)
        draw(document, base: base, pixelated: pixelated, blurred: blurred, in: context)
        return context.makeImage()
    }

    public static func textAttributes(fontSize: CGFloat, color: AnnotationColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color.nsColor]
    }

    public static func textSize(_ string: String, fontSize: CGFloat) -> CGSize {
        let size = (string as NSString).size(withAttributes: textAttributes(fontSize: fontSize, color: .black))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: Shapes

    private static func draw(_ annotation: Annotation, effects: Effects, in context: CGContext) {
        let color = annotation.color.cgColor
        context.saveGState()
        defer { context.restoreGState() }

        switch annotation.shape {
        case .rectangle(let rect):
            context.setStrokeColor(color)
            context.setLineWidth(annotation.lineWidth)
            context.setLineJoin(.round)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.strokePath()

        case .mosaic(let rect):
            context.clip(to: rect)
            if let pixelated = effects.pixelated {
                drawImage(pixelated, in: effects.canvas, context: context)
            } else {
                context.setFillColor(NSColor.gray.cgColor)
                context.fill(rect)
            }

        case .blur(let rect):
            context.clip(to: rect)
            if let blurred = effects.blurred {
                drawImage(blurred, in: effects.canvas, context: context)
            } else {
                context.setFillColor(NSColor.gray.cgColor)
                context.fill(rect)
            }

        case .pen(let points):
            context.setStrokeColor(color)
            context.setLineWidth(annotation.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(smoothPath(through: points))
            context.strokePath()

        case .highlight(let points):
            // A marker: wide, see-through, and multiplied so text under it stays readable.
            context.setBlendMode(.multiply)
            context.setStrokeColor(annotation.color.cgColor.copy(alpha: 0.4) ?? color)
            context.setLineWidth(annotation.strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(smoothPath(through: points))
            context.strokePath()

        case .line(let from, let to):
            context.setStrokeColor(color)
            context.setLineWidth(annotation.lineWidth)
            context.setLineCap(.round)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case .ellipse(let rect):
            context.setStrokeColor(color)
            context.setLineWidth(annotation.lineWidth)
            context.strokeEllipse(in: rect)

        case .magnifier(let rect):
            drawMagnifier(in: rect, color: color, effects: effects, context: context)

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, lineWidth: annotation.lineWidth, color: color, in: context)

        case .text(let string, let frame, let fontSize):
            withAppKitContext(context) {
                (string as NSString).draw(at: frame.origin, withAttributes: textAttributes(fontSize: fontSize, color: annotation.color))
            }

        case .counter(let number, let center):
            let radius = Annotation.counterRadius(forLineWidth: annotation.lineWidth)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(color)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))

            let label = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.1, weight: .bold),
                .foregroundColor: annotation.color.isLight ? NSColor.black : NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            withAppKitContext(context) {
                label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
            }
        }
    }

    /// A smooth curve through the points: each segment bends through the midpoints, so a quick
    /// hand-drawn stroke doesn't look jagged.
    private static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            if points.count == 1 { path.addLine(to: first) }
            return path
        }
        for index in 1 ..< points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// A round lens: what's under its middle, enlarged, inside a ring in the annotation's color
    /// with a soft shadow, like a loupe laid on the picture.
    private static func drawMagnifier(in rect: CGRect, color: CGColor, effects: Effects, context: CGContext) {
        let circle = CGRect(x: rect.midX - rect.width / 2, y: rect.midY - rect.width / 2, width: rect.width, height: rect.width)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: circle)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        // Scale the canvas about the lens's center.
        let zoom = Annotation.magnifierZoom
        context.translateBy(x: circle.midX, y: circle.midY)
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -circle.midX, y: -circle.midY)
        drawImage(effects.base, in: effects.canvas, context: context)
        context.restoreGState()

        context.setStrokeColor(color)
        context.setLineWidth(3)
        context.strokeEllipse(in: circle.insetBy(dx: 1.5, dy: 1.5))
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, color: CGColor, in context: CGContext) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }

        let headLength = min(length, max(14, lineWidth * 4.5))
        let headWidth = headLength * 0.9
        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let headBase = CGPoint(x: to.x - unit.x * headLength, y: to.y - unit.y * headLength)

        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: from)
        context.addLine(to: headBase)
        context.strokePath()

        context.setFillColor(color)
        context.move(to: to)
        context.addLine(to: CGPoint(x: headBase.x + normal.x * headWidth / 2, y: headBase.y + normal.y * headWidth / 2))
        context.addLine(to: CGPoint(x: headBase.x - normal.x * headWidth / 2, y: headBase.y - normal.y * headWidth / 2))
        context.closePath()
        context.fillPath()
    }

    // MARK: Helpers

    /// CGContext.draw puts images upside down in a top-left-origin space; flip locally.
    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func withAppKitContext(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

public extension AnnotationColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
