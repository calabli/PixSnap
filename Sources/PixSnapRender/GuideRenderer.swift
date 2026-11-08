import AppKit
import CoreGraphics
import PixSnapCore

/// 图文教程's pictures: each step's frame with where it was clicked made plain (the rest dimmed, a
/// ring round the spot, the step's number beside it), and the whole guide as one long image.
public enum GuideRenderer {
    private static let blue = CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

    /// `image` for step `number`, the click at `x`, `y` (fractions from the top-left) circled with
    /// `radius` pixels; without a click, just the number in the corner.
    public static func annotate(_ image: CGImage, number: Int, x: Double?, y: Double?, radius: CGFloat) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: canvas)
        let badgeSize = max(28, radius * 0.9)
        var badgeCenter = CGPoint(x: badgeSize * 0.8, y: CGFloat(height) - badgeSize * 0.8)
        if let x, let y {
            let center = CGPoint(x: CGFloat(x) * CGFloat(width), y: (1 - CGFloat(y)) * CGFloat(height))
            let spot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            // Everything but the spot, dimmed.
            let dim = CGMutablePath()
            dim.addRect(canvas)
            dim.addEllipse(in: spot)
            context.addPath(dim)
            context.setFillColor(CGColor(gray: 0, alpha: 0.3))
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(blue)
            context.setLineWidth(max(3, radius / 10))
            context.strokeEllipse(in: spot)
            // The number at the ring's top right, kept on the picture.
            let offset = radius * 0.75
            badgeCenter = CGPoint(x: min(max(center.x + offset, badgeSize), CGFloat(width) - badgeSize),
                                  y: min(max(center.y + offset, badgeSize), CGFloat(height) - badgeSize))
        }
        drawBadge(number, at: badgeCenter, size: badgeSize, in: context)
        return context.makeImage()
    }

    private static func drawBadge(_ number: Int, at center: CGPoint, size: CGFloat, in context: CGContext) {
        let circle = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(gray: 0, alpha: 0.35))
        context.setFillColor(blue)
        context.fillEllipse(in: circle)
        context.restoreGState()
        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.55, weight: .bold), .foregroundColor: NSColor.white]
        let textSize = text.size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The guide as one image `width` pixels wide: the title, then each step's heading and picture.
    public static func longImage(title: String, steps: [(title: String, image: CGImage)], width: CGFloat = 1200) -> CGImage? {
        let margin: CGFloat = 56, inner = width - margin * 2
        let titleFont = NSFont.systemFont(ofSize: 40, weight: .bold), headingFont = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let titleHeight = textHeight(title, font: titleFont, width: inner)
        var height = margin + titleHeight + 40
        let laid = steps.enumerated().map { index, step -> (heading: String, headingHeight: CGFloat, image: CGImage, size: CGSize) in
            let heading = "\(index + 1). \(step.title)"
            let fit = min(1, inner / CGFloat(step.image.width))
            let size = CGSize(width: (CGFloat(step.image.width) * fit).rounded(), height: (CGFloat(step.image.height) * fit).rounded())
            return (heading, textHeight(heading, font: headingFont, width: inner), step.image, size)
        }
        for step in laid { height += step.headingHeight + 16 + step.size.height + 48 }
        height += margin - 48

        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Laid out from the top down; Core Graphics counts from the bottom.
        var top = height - margin
        draw(title, font: titleFont, color: .black, in: CGRect(x: margin, y: top - titleHeight, width: inner, height: titleHeight))
        top -= titleHeight + 40
        for step in laid {
            draw(step.heading, font: headingFont, color: NSColor(white: 0.12, alpha: 1),
                 in: CGRect(x: margin, y: top - step.headingHeight, width: inner, height: step.headingHeight))
            top -= step.headingHeight + 16
            let frame = CGRect(x: margin, y: top - step.size.height, width: step.size.width, height: step.size.height)
            context.saveGState()
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.clip()
            context.draw(step.image, in: frame)
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
            context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.strokePath()
            top -= step.size.height + 48
        }
        return context.makeImage()
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin], attributes: [.font: font]).height)
    }

    private static func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect) {
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [.font: font, .foregroundColor: color])
    }
}
