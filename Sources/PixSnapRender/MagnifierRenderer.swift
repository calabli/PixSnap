import AppKit
import PixSnapCore

/// The loupe shown next to the cursor while selecting: the pixels around the cursor, enlarged,
/// with the cursor's pixel outlined, and below it the pixel position and its color.
@MainActor
public enum MagnifierRenderer {
    /// Pixels across the loupe; odd, so one pixel sits in the middle.
    public static let cellsAcross = 15
    public static let loupeSide: CGFloat = 120
    public static let infoHeight: CGFloat = 40
    public static var size: CGSize { CGSize(width: loupeSide, height: loupeSide + infoHeight) }

    /// Distance between the cursor and the magnifier's nearest corner.
    private static let cursorGap: CGFloat = 22

    /// The color of one pixel (top-left origin), converted to sRGB.
    public static func color(at pixel: PixelPoint, in image: CGImage) -> PixelColor? {
        guard let single = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? PixelColor(red: bytes[0], green: bytes[1], blue: bytes[2]) : nil
    }

    /// Bottom-left corner for the magnifier: below and to the right of the cursor, moved to the
    /// other side of the cursor when it would leave `bounds` (bottom-left-origin coordinates).
    public static func origin(forCursor cursor: CGPoint, in bounds: CGRect) -> CGPoint {
        var origin = CGPoint(x: cursor.x + cursorGap, y: cursor.y - cursorGap - size.height)
        if origin.x + size.width > bounds.maxX { origin.x = cursor.x - cursorGap - size.width }
        if origin.y < bounds.minY { origin.y = cursor.y + cursorGap }
        return origin
    }

    /// Draws the magnifier with its bottom-left corner at `origin`, in a context whose
    /// coordinates have a bottom-left origin (AppKit's default).
    public static func draw(image: CGImage, pixel: PixelPoint, at origin: CGPoint, in context: CGContext) {
        let frame = CGRect(origin: origin, size: size)
        let loupe = CGRect(x: origin.x, y: origin.y + infoHeight, width: loupeSide, height: loupeSide)
        let cell = loupeSide / CGFloat(cellsAcross)
        let half = cellsAcross / 2
        let outline = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)

        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.setFillColor(NSColor(white: 0.08, alpha: 0.92).cgColor)
        context.fill(frame)

        // The pixels around the cursor. Near the image edge only part of the square exists;
        // that part is drawn where it belongs and the rest stays dark.
        let source = CGRect(x: pixel.x - half, y: pixel.y - half, width: cellsAcross, height: cellsAcross)
        let available = source.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !available.isNull, let pixels = image.cropping(to: available) {
            let destination = CGRect(
                x: loupe.minX + (available.minX - source.minX) * cell,
                y: loupe.maxY - (available.maxY - source.minY) * cell,
                width: available.width * cell,
                height: available.height * cell
            )
            context.interpolationQuality = .none
            context.draw(pixels, in: destination)
        }

        // Faint grid, then the cursor's pixel.
        context.setStrokeColor(NSColor(white: 1, alpha: 0.08).cgColor)
        context.setLineWidth(0.5)
        for index in 1..<cellsAcross {
            let offset = CGFloat(index) * cell
            context.move(to: CGPoint(x: loupe.minX + offset, y: loupe.minY))
            context.addLine(to: CGPoint(x: loupe.minX + offset, y: loupe.maxY))
            context.move(to: CGPoint(x: loupe.minX, y: loupe.minY + offset))
            context.addLine(to: CGPoint(x: loupe.maxX, y: loupe.minY + offset))
        }
        context.strokePath()

        let center = CGRect(x: loupe.minX + CGFloat(half) * cell, y: loupe.minY + CGFloat(half) * cell, width: cell, height: cell)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(2)
        context.stroke(center.insetBy(dx: -1, dy: -1))
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(center.insetBy(dx: -1, dy: -1))

        context.setStrokeColor(NSColor(white: 1, alpha: 0.2).cgColor)
        context.move(to: CGPoint(x: loupe.minX, y: loupe.minY))
        context.addLine(to: CGPoint(x: loupe.maxX, y: loupe.minY))
        context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.addPath(outline)
        context.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        drawInfo(color: color(at: pixel, in: image), pixel: pixel, in: CGRect(x: origin.x, y: origin.y, width: loupeSide, height: infoHeight), context: context)
    }

    private static func drawInfo(color: PixelColor?, pixel: PixelPoint, in rect: CGRect, context: CGContext) {
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let position: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor(white: 1, alpha: 0.75)]
        let hex: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 1, alpha: 0.5)]

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("X \(pixel.x)  Y \(pixel.y)" as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 22), withAttributes: position)
        if let color {
            let swatch = CGRect(x: rect.minX + 8, y: rect.minY + 7, width: 11, height: 11)
            NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
            NSColor(white: 1, alpha: 0.5).setStroke()
            NSBezierPath(roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            (color.hex as NSString).draw(at: CGPoint(x: swatch.maxX + 5, y: rect.minY + 5), withAttributes: hex)
            let label = "C 复制" as NSString
            let width = label.size(withAttributes: hint).width
            label.draw(at: CGPoint(x: rect.maxX - 8 - width, y: rect.minY + 6), withAttributes: hint)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
