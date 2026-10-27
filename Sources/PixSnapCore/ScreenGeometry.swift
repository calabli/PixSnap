import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Multi-display geometry in AppKit's global coordinates: bottom-left origin at the primary
/// display's bottom-left corner. Other displays can sit at negative x or above the primary.
public enum ScreenGeometry {
    /// Converts a CoreGraphics global rect (window bounds, display bounds), whose origin is the
    /// primary display's top-left corner with y growing down, to AppKit coordinates.
    public static func appKitRect(fromCGRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Whether `point` is on the screen with `frame`, using AppKit's mouse rules: the left and top
    /// edges belong to the screen, the right and bottom edges to its neighbours.
    public static func screen(_ frame: CGRect, containsMouse point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
    }

    /// Indices of `frames` with the screen under `point` first and the rest in their original order.
    public static func indicesStartingWithScreen(under point: CGPoint, in frames: [CGRect]) -> [Int] {
        let under = frames.indices.filter { screen(frames[$0], containsMouse: point) }
        return under + frames.indices.filter { !under.contains($0) }
    }

    /// Whether at least `minimumVisible` points of `frame`, in both directions, are on some screen,
    /// so its window can still be seen and dragged back.
    public static func isReachable(_ frame: CGRect, on screens: [CGRect], minimumVisible: CGFloat = 40) -> Bool {
        screens.contains { screen in
            let overlap = frame.intersection(screen)
            return !overlap.isNull && overlap.width >= minimumVisible && overlap.height >= minimumVisible
        }
    }

    /// `size` centered in `container`, rounded to whole points.
    public static func centered(_ size: CGSize, in container: CGRect) -> CGRect {
        CGRect(
            x: (container.midX - size.width / 2).rounded(),
            y: (container.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}
