import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry helpers for the selection overlay. View rects use a bottom-left origin in points
/// (AppKit's default); captured images use a top-left origin in pixels.
public enum SelectionGeometry {
    /// Drags smaller than this (in points) count as a click, which selects the hovered window instead.
    public static let minimumDragSize: CGFloat = 4

    public static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public static func isDrag(_ rect: CGRect) -> Bool {
        rect.width >= minimumDragSize && rect.height >= minimumDragSize
    }

    /// The handle on `rect`'s edge or corner under `point`, if any. A whole edge can be grabbed,
    /// not only its middle; near a corner, the corner wins.
    public static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> SelectionHandle? {
        guard point.x >= rect.minX - tolerance, point.x <= rect.maxX + tolerance,
              point.y >= rect.minY - tolerance, point.y <= rect.maxY + tolerance else { return nil }
        // On a selection narrower than the grab area, the nearer edge.
        func nearer(_ low: CGFloat, _ high: CGFloat, _ value: CGFloat) -> Int {
            let toLow = abs(value - low), toHigh = abs(value - high)
            if toLow <= tolerance, toLow <= toHigh { return -1 }
            if toHigh <= tolerance { return 1 }
            return 0
        }
        switch (nearer(rect.minX, rect.maxX, point.x), nearer(rect.minY, rect.maxY, point.y)) {
        case (-1, -1): return .bottomLeft
        case (0, -1): return .bottom
        case (1, -1): return .bottomRight
        case (1, 0): return .right
        case (1, 1): return .topRight
        case (0, 1): return .top
        case (-1, 1): return .topLeft
        case (-1, 0): return .left
        default: return nil
        }
    }

    /// `rect` with the edges `handle` holds moved by `delta`, kept inside `bounds`. Dragging an edge
    /// past the opposite one flips the selection over, as it would when drawing it.
    public static func resized(_ rect: CGRect, by handle: SelectionHandle, delta: CGSize, within bounds: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, bounds.minX), bounds.maxX) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, bounds.minY), bounds.maxY) }
        if handle.horizontal < 0 { minX = clampX(minX + delta.width) }
        if handle.horizontal > 0 { maxX = clampX(maxX + delta.width) }
        if handle.vertical < 0 { minY = clampY(minY + delta.height) }
        if handle.vertical > 0 { maxY = clampY(maxY + delta.height) }
        return Self.rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
    }

    /// `rect` moved by `delta`, stopping at the edges of `bounds` without changing size.
    public static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        let x = min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The image pixel (top-left origin) under a point in the view (bottom-left origin), clamped to the image.
    public static func pixelPoint(forViewPoint point: CGPoint, viewSize: CGSize, imageSize: CGSize) -> PixelPoint {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width >= 1, imageSize.height >= 1 else {
            return PixelPoint(x: 0, y: 0)
        }
        let x = Int((point.x * imageSize.width / viewSize.width).rounded(.down))
        let y = Int(((viewSize.height - point.y) * imageSize.height / viewSize.height).rounded(.down))
        return PixelPoint(
            x: min(max(x, 0), Int(imageSize.width) - 1),
            y: min(max(y, 0), Int(imageSize.height) - 1)
        )
    }

    /// Maps a selection in view points to the matching pixel rect of the captured image,
    /// clipped to the image and rounded outward to whole pixels.
    public static func pixelRect(forViewRect rect: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let clipped = rect.intersection(CGRect(origin: .zero, size: viewSize))
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }

        let scaleX = imageSize.width / viewSize.width
        let scaleY = imageSize.height / viewSize.height
        let flipped = CGRect(
            x: clipped.minX * scaleX,
            y: (viewSize.height - clipped.maxY) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        )
        let result = flipped.integral.intersection(CGRect(origin: .zero, size: imageSize))
        return result.isNull ? .zero : result
    }
}

/// A grab point on the selection's edge, for resizing it.
public enum SelectionHandle: CaseIterable, Sendable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

    /// Which vertical edge it moves: -1 the left, 1 the right, 0 neither.
    public var horizontal: Int {
        switch self {
        case .bottomLeft, .left, .topLeft: -1
        case .bottomRight, .right, .topRight: 1
        case .bottom, .top: 0
        }
    }

    /// Which horizontal edge it moves: -1 the bottom, 1 the top, 0 neither (bottom-left origin).
    public var vertical: Int {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: -1
        case .topLeft, .top, .topRight: 1
        case .left, .right: 0
        }
    }

    /// Where it is drawn on `rect`.
    public func point(on rect: CGRect) -> CGPoint {
        CGPoint(x: horizontal < 0 ? rect.minX : horizontal > 0 ? rect.maxX : rect.midX,
                y: vertical < 0 ? rect.minY : vertical > 0 ? rect.maxY : rect.midY)
    }
}
