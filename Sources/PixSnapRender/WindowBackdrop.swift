import CoreGraphics
import Foundation
import PixSnapCore

/// Finishes a captured window: a soft shadow like the one macOS draws under windows, and/or a
/// background with room around it (a gradient or a plain color), the window centered. The window
/// keeps its own rounded corners.
public enum WindowBackdrop {
    /// Room around the window on a background, in points.
    public static let padding: CGFloat = 56
    /// Room for the shadow alone, on transparency, in points.
    public static let shadowRoom: CGFloat = 44
    /// The shadow: blurred this much, and dropped this far, in points.
    static let shadowBlur: CGFloat = 36
    static let shadowDrop: CGFloat = 14

    /// `window` at `scale` pixels per point. With neither shadow nor background, it comes back unchanged.
    public static func render(_ window: CGImage, scale: CGFloat, background: WindowCaptureStyle.Background, shadow: Bool) -> CGImage? {
        let colors = colors(for: background)
        guard colors != nil || shadow else { return window }
        let inset = Int(((colors == nil ? shadowRoom : padding) * scale).rounded())
        let width = window.width + inset * 2, height = window.height + inset * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let colors {
            let cgColors = colors.map { CGColor(colorSpace: space, components: [$0.red, $0.green, $0.blue, 1])! } as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil) {
                // Top-left to bottom-right.
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
            }
        }
        if shadow {
            context.setShadow(offset: CGSize(width: 0, height: -shadowDrop * scale), blur: shadowBlur * scale,
                              color: CGColor(colorSpace: space, components: [0, 0, 0, 0.45]))
        }
        context.draw(window, in: CGRect(x: inset, y: inset, width: window.width, height: window.height))
        return context.makeImage()
    }

    /// Two colors for a gradient (the same twice for a plain color); nil for no background.
    static func colors(for background: WindowCaptureStyle.Background) -> [(red: CGFloat, green: CGFloat, blue: CGFloat)]? {
        switch background {
        case .none: nil
        case .sunrise: [(1.00, 0.72, 0.42), (0.95, 0.38, 0.55)]
        case .ocean: [(0.33, 0.73, 0.98), (0.27, 0.36, 0.88)]
        case .mint: [(0.62, 0.93, 0.78), (0.20, 0.70, 0.62)]
        case .lavender: [(0.86, 0.78, 1.00), (0.56, 0.47, 0.93)]
        case .graphite: [(0.36, 0.38, 0.42), (0.13, 0.14, 0.16)]
        case .white: [(0.97, 0.97, 0.97), (0.97, 0.97, 0.97)]
        }
    }
}
