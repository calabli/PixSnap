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

    /// The handle at the chosen size: `base` (the notch, or the stand-in bar) made narrower or wider
    /// about its center. Over a notch it keeps the notch's height; the stand-in bar grows both ways.
    public static func handleRect(_ base: CGRect, size: NotchHandleSize, isNotch: Bool) -> CGRect {
        let width = (base.width * size.scale).rounded()
        let height = isNotch ? base.height : (base.height * size.scale).rounded()
        return CGRect(x: (base.midX - width / 2).rounded(), y: base.maxY - height, width: width, height: height)
    }

    /// The handle beside the notch instead of on it, leaving the notch to another app: a bar like
    /// the stand-in one (sized by `size`), hanging from the top edge `gap` points from the notch.
    /// Without a notch, `notch` is nil and the bar keeps clear of the middle 220 points, where
    /// notch apps put their own.
    public static func besideRect(notch: CGRect?, screenFrame: CGRect, size: NotchHandleSize, position: NotchHandlePosition,
                                  gap: CGFloat = 10) -> CGRect {
        let width = (120 * size.scale).rounded(), height = (8 * size.scale).rounded()
        let reserved = notch ?? CGRect(x: screenFrame.midX - 110, y: screenFrame.maxY - height, width: 220, height: height)
        var x = position == .left ? reserved.minX - gap - width : reserved.maxX + gap
        x = min(max(x, screenFrame.minX), screenFrame.maxX - width)
        return CGRect(x: x.rounded(), y: screenFrame.maxY - height, width: width, height: height)
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

/// How big the pull-down handle is.
public enum NotchHandleSize: String, CaseIterable, Codable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }

    /// Against the notch's own width (or the 120 × 8 bar on other screens).
    public var scale: CGFloat {
        switch self {
        case .small: 0.75
        case .medium: 1
        case .large: 1.5
        }
    }
}

/// Where the pull-down handle sits: on the notch, or beside it when another app uses the notch.
public enum NotchHandlePosition: String, CaseIterable, Codable, Sendable {
    case notch, left, right

    public var title: String {
        switch self {
        case .notch: "刘海处"
        case .left: "刘海左边"
        case .right: "刘海右边"
        }
    }
}
