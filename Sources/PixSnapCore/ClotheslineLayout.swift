import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Sizes and spacing for photos on the clothesline, and the size of the space-bar preview.
public enum ClotheslineLayout {
    /// Every photo fits in this box, keeping the capture's shape.
    public static let maximumPhotoSize = CGSize(width: 150, height: 90)
    /// Very long or very tall captures don't shrink to a sliver; they're cropped to this instead.
    public static let minimumPhotoSide: CGFloat = 26
    /// The smallest space left between neighboring photos.
    public static let minimumGap: CGFloat = 18

    /// The capture's shape, scaled to fit the photo box.
    public static func photoSize(pixelWidth: Int, pixelHeight: Int) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else { return maximumPhotoSize }
        let box = maximumPhotoSize
        let scale = min(box.width / CGFloat(pixelWidth), box.height / CGFloat(pixelHeight))
        return CGSize(width: max(minimumPhotoSide, (CGFloat(pixelWidth) * scale).rounded()),
                      height: max(minimumPhotoSide, (CGFloat(pixelHeight) * scale).rounded()))
    }

    /// How many of the newest photos fit along a rope `length` long. `widths` are oldest first,
    /// like the photos on the line, so the count is taken from the end.
    public static func fittingCount(widths: [CGFloat], length: CGFloat) -> Int {
        var used = minimumGap
        var count = 0
        for width in widths.reversed() {
            used += width + minimumGap
            guard used <= length else { break }
            count += 1
        }
        return count
    }

    /// The center of each photo along the rope, measured from its start, with equal space between
    /// neighbors and at both ends.
    public static func centers(widths: [CGFloat], length: CGFloat) -> [CGFloat] {
        let gap = (length - widths.reduce(0, +)) / CGFloat(widths.count + 1)
        var x = gap
        return widths.map { width in
            defer { x += width + gap }
            return x + width / 2
        }
    }

    /// The preview fits inside `bounds` with the capture's shape, never larger than its own size.
    public static func previewSize(imageSize: CGSize, bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(1, bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
    }
}
