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
