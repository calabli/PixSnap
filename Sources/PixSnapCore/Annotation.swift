import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An sRGB color, kept platform-neutral so the model can be shared with other platforms.
public struct AnnotationColor: Equatable, Codable, Sendable {
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

/// How an arrow's ends look.
public enum ArrowStyle: String, CaseIterable, Codable, Sendable {
    /// A solid triangle at the end.
    case filled
    /// Two strokes at the end, like a hand-drawn arrow.
    case open
    /// Solid heads at both ends.
    case double

    public var title: String {
        switch self {
        case .filled: "实心箭头"
        case .open: "线条箭头"
        case .double: "双向箭头"
        }
    }
}

/// The typeface for text annotations.
public enum TextFont: String, CaseIterable, Codable, Sendable {
    case system, rounded, serif, kai, mono

    public var title: String {
        switch self {
        case .system: "苹方"
        case .rounded: "圆体"
        case .serif: "宋体"
        case .kai: "楷体"
        case .mono: "等宽"
        }
    }
}

/// Geometry of an annotation in canvas points with a top-left origin.
public enum AnnotationShape: Equatable, Sendable {
    case rectangle(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    /// `frame` is measured by the platform layer from the font, so hit testing needs no text layout here.
    case text(String, frame: CGRect, fontSize: CGFloat)
    case counter(Int, center: CGPoint)
    case mosaic(CGRect)
    /// A freehand stroke through these points.
    case pen([CGPoint])
    /// A see-through marker stroke, drawn wide and multiplied over what's under it.
    case highlight([CGPoint])
    case line(from: CGPoint, to: CGPoint)
    case ellipse(CGRect)
    /// What's inside is blurred, softer than the mosaic.
    case blur(CGRect)
    /// A round lens over its rect, showing what's under its middle at `zoom` times.
    case magnifier(CGRect)
    /// A measuring line with end ticks, labelled with its length in the screenshot's pixels.
    case ruler(from: CGPoint, to: CGPoint)
}

public struct Annotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var shape: AnnotationShape
    public var color: AnnotationColor
    public var lineWidth: CGFloat
    /// For arrows.
    public var arrowStyle: ArrowStyle
    /// For text.
    public var font: TextFont

    public init(id: UUID = UUID(), shape: AnnotationShape, color: AnnotationColor, lineWidth: CGFloat,
                arrowStyle: ArrowStyle = .filled, font: TextFont = .system) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
        self.arrowStyle = arrowStyle
        self.font = font
    }

    public static func counterRadius(forLineWidth lineWidth: CGFloat) -> CGFloat {
        10 + lineWidth * 1.5
    }

    /// Marker strokes are this many times wider than the chosen line width.
    public static let highlightWidthFactor: CGFloat = 4
    /// How much the magnifier enlarges.
    public static let magnifierZoom: CGFloat = 2

    /// How wide the stroke actually is.
    public var strokeWidth: CGFloat {
        if case .highlight = shape { return lineWidth * Self.highlightWidthFactor }
        return lineWidth
    }

    public var bounds: CGRect {
        switch shape {
        case .rectangle(let rect), .mosaic(let rect), .ellipse(let rect), .blur(let rect), .magnifier(let rect):
            return rect
        case .arrow(let from, let to), .line(let from, let to), .ruler(let from, let to):
            return SelectionGeometry.rect(from: from, to: to)
        case .pen(let points), .highlight(let points):
            return Self.bounds(of: points).insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
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
        case .arrow(let from, let to), .line(let from, let to), .ruler(let from, let to):
            return Self.distance(from: point, toSegmentFrom: from, to: to) <= tolerance + lineWidth / 2
        case .pen(let points), .highlight(let points):
            let reach = tolerance + strokeWidth / 2
            guard points.count > 1 else { return points.first.map { hypot(point.x - $0.x, point.y - $0.y) <= reach } ?? false }
            return zip(points, points.dropFirst()).contains { Self.distance(from: point, toSegmentFrom: $0, to: $1) <= reach }
        case .ellipse(let rect):
            // Near the outline: the point's distance from the ellipse, measured along its radius.
            let rx = max(rect.width / 2, 1), ry = max(rect.height / 2, 1)
            let dx = (point.x - rect.midX) / rx, dy = (point.y - rect.midY) / ry
            let r = (dx * dx + dy * dy).squareRoot()
            return abs(r - 1) * min(rx, ry) <= tolerance + lineWidth / 2
        case .magnifier(let rect):
            return hypot(point.x - rect.midX, point.y - rect.midY) <= rect.width / 2 + tolerance
        case .text, .counter, .mosaic, .blur:
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
        case .ellipse(let rect):
            moved.shape = .ellipse(rect.offsetBy(dx: dx, dy: dy))
        case .blur(let rect):
            moved.shape = .blur(rect.offsetBy(dx: dx, dy: dy))
        case .magnifier(let rect):
            moved.shape = .magnifier(rect.offsetBy(dx: dx, dy: dy))
        case .pen(let points):
            moved.shape = .pen(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        case .highlight(let points):
            moved.shape = .highlight(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        case .line(let from, let to):
            moved.shape = .line(from: CGPoint(x: from.x + dx, y: from.y + dy), to: CGPoint(x: to.x + dx, y: to.y + dy))
        case .arrow(let from, let to):
            moved.shape = .arrow(from: CGPoint(x: from.x + dx, y: from.y + dy), to: CGPoint(x: to.x + dx, y: to.y + dy))
        case .ruler(let from, let to):
            moved.shape = .ruler(from: CGPoint(x: from.x + dx, y: from.y + dy), to: CGPoint(x: to.x + dx, y: to.y + dy))
        case .text(let string, let frame, let fontSize):
            moved.shape = .text(string, frame: frame.offsetBy(dx: dx, dy: dy), fontSize: fontSize)
        case .counter(let number, let center):
            moved.shape = .counter(number, center: CGPoint(x: center.x + dx, y: center.y + dy))
        }
        return moved
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect
    }

    /// Where a line from `from` toward `to` ends when Shift snaps it to the nearest 45°.
    public static func snapped(from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: from.x + cos(angle) * length, y: from.y + sin(angle) * length)
    }

    /// A ruler's reading: its length in the screenshot's pixels (`scale` pixels per point), with
    /// "宽"/"高" for a level or upright one.
    public static func rulerLabel(from: CGPoint, to: CGPoint, scale: CGFloat) -> String {
        let dx = abs(to.x - from.x) * scale, dy = abs(to.y - from.y) * scale
        if dy < 0.5 { return "宽 \(Int(dx.rounded())) px" }
        if dx < 0.5 { return "高 \(Int(dy.rounded())) px" }
        return "\(Int(hypot(dx, dy).rounded())) px"
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
