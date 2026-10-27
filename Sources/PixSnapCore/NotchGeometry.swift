import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the pull-down handle sits and how it grows, in AppKit screen coordinates (bottom-left origin).
public enum NotchGeometry {
    /// The camera notch, found between the two menu bar areas on either side of it.
    /// Returns nil on screens without a notch.
    public static func notchRect(screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?, safeAreaTop: CGFloat) -> CGRect? {
        guard safeAreaTop > 0, let left = topLeftArea, let right = topRightArea, right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: screenFrame.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
    }

    /// A small stand-in handle at the top center of screens without a notch.
    public static func standInRect(screenFrame: CGRect, width: CGFloat = 120, height: CGFloat = 8) -> CGRect {
        CGRect(x: (screenFrame.midX - width / 2).rounded(), y: screenFrame.maxY - height, width: width, height: height)
    }

    /// The handle while the mouse is over it: a little wider and taller, still hanging from the top.
    public static func hoverRect(for collapsed: CGRect, extraWidth: CGFloat = 40, extraHeight: CGFloat = 20) -> CGRect {
        CGRect(x: collapsed.minX - extraWidth / 2, y: collapsed.minY - extraHeight,
               width: collapsed.width + extraWidth, height: collapsed.height + extraHeight)
    }

    /// The open panel: `size`, centered under the handle, kept on screen with `margin` at the sides,
    /// and hanging from the top of the screen.
    public static func openRect(size: CGSize, under collapsed: CGRect, screenFrame: CGRect, margin: CGFloat = 24) -> CGRect {
        let width = min(size.width, screenFrame.width - margin * 2)
        let x = min(max(collapsed.midX - width / 2, screenFrame.minX + margin), screenFrame.maxX - margin - width)
        return CGRect(x: x.rounded(), y: screenFrame.maxY - size.height, width: width, height: size.height)
    }

    /// Between `collapsed` (progress 0) and `open` (progress 1), always hanging from the same top edge.
    public static func frame(from collapsed: CGRect, to open: CGRect, progress: CGFloat) -> CGRect {
        let p = max(0, min(1, progress))
        let width = collapsed.width + (open.width - collapsed.width) * p
        let height = collapsed.height + (open.height - collapsed.height) * p
        let midX = collapsed.midX + (open.midX - collapsed.midX) * p
        return CGRect(x: midX - width / 2, y: collapsed.maxY - height, width: width, height: height)
    }

    /// How open the panel is after dragging `distance` points; it follows the mouse one to one.
    public static func progress(forDrag distance: CGFloat, collapsed: CGRect, open: CGRect) -> CGFloat {
        let range = open.height - collapsed.height
        guard range > 0 else { return 1 }
        return max(0, min(1, distance / range))
    }
}
