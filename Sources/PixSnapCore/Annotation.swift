import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An sRGB color, kept platform-neutral so the model can be shared with other platforms.
public struct AnnotationColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = AnnotationColor(red: 0.95, green: 0.23, blue: 0.19)
    public static let yellow = AnnotationColor(red: 1.0, green: 0.78, blue: 0.0)
    public static let green = AnnotationColor(red: 0.20, green: 0.78, blue: 0.35)
    public static let blue = AnnotationColor(red: 0.0, green: 0.48, blue: 1.0)
    public static let black = AnnotationColor(red: 0.11, green: 0.11, blue: 0.12)
    public static let white = AnnotationColor(red: 1, green: 1, blue: 1)

    public static let palette: [AnnotationColor] = [.red, .yellow, .green, .blue, .black, .white]

    /// Perceived brightness, used to pick readable text on top of this color.
    public var isLight: Bool { red * 0.299 + green * 0.587 + blue * 0.114 > 0.6 }
}

/// Geometry of an annotation in canvas points with a top-left origin.
public enum AnnotationShape: Equatable, Sendable {
    case rectangle(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    /// `frame` is measured by the platform layer from the font, so hit testing needs no text layout here.
    case text(String, frame: CGRect, fontSize: CGFloat)
    case counter(Int, center: CGPoint)
    case mosaic(CGRect)
}

public struct Annotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var shape: AnnotationShape
    public var color: AnnotationColor
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), shape: AnnotationShape, color: AnnotationColor, lineWidth: CGFloat) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }

    public static func counterRadius(forLineWidth lineWidth: CGFloat) -> CGFloat {
        10 + lineWidth * 1.5
    }

    public var bounds: CGRect {
        switch shape {
        case .rectangle(let rect), .mosaic(let rect):
            return rect
        case .arrow(let from, let to):
            return SelectionGeometry.rect(from: from, to: to)
        case .text(_, let frame, _):
            return frame
        case .counter(_, let center):
            let radius = Self.counterRadius(forLineWidth: lineWidth)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Rectangles are hit on their outline only, so you can still click things inside them.
    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch shape {
        case .rectangle(let rect):
            let slack = tolerance + lineWidth / 2
            return rect.insetBy(dx: -slack, dy: -slack).contains(point)
                && !rect.insetBy(dx: slack, dy: slack).contains(point)
        case .arrow(let from, let to):
            return Self.distance(from: point, toSegmentFrom: from, to: to) <= tolerance + lineWidth / 2
        case .text, .counter, .mosaic:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    public func translated(dx: CGFloat, dy: CGFloat) -> Annotation {
        var moved = self
        switch shape {
        case .rectangle(let rect):
            moved.shape = .rectangle(rect.offsetBy(dx: dx, dy: dy))
        case .mosaic(let rect):
            moved.shape = .mosaic(rect.offsetBy(dx: dx, dy: dy))
        case .arrow(let from, let to):
            moved.shape = .arrow(from: CGPoint(x: from.x + dx, y: from.y + dy), to: CGPoint(x: to.x + dx, y: to.y + dy))
        case .text(let string, let frame, let fontSize):
            moved.shape = .text(string, frame: frame.offsetBy(dx: dx, dy: dy), fontSize: fontSize)
        case .counter(let number, let center):
            moved.shape = .counter(number, center: CGPoint(x: center.x + dx, y: center.y + dy))
        }
        return moved
    }

    static func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
