import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Sizes and spacing for photos on the clothesline, and the size of the space-bar preview.
public enum ClotheslineLayout {
    /// Small previews (the basket) fit in this box, keeping the capture's shape.
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

    /// The smallest a photo's height gets before older photos drop off the line instead.
    public static let minimumRowHeight: CGFloat = 56

    /// Sizes for a line of photos that use the rope well: the fewer there are, the bigger they
    /// hang, all at one height where they can, but never larger than the capture itself
    /// (`pointSizes`, oldest first) or `maxHeight`. Every photo takes `padding` more room than its
    /// picture. When even the smallest height can't fit them all, the oldest drop off: the result
    /// is the sizes of the newest photos that fit, oldest first.
    public static func photoSizes(pointSizes: [CGSize], ropeLength: CGFloat, maxHeight: CGFloat, padding: CGFloat = 0) -> [CGSize] {
        guard !pointSizes.isEmpty else { return [] }
        let low = min(minimumRowHeight, maxHeight)
        // Panoramas don't take over the whole rope.
        let maxWidth = max(ropeLength * 0.45, minimumPhotoSide)

        func size(_ source: CGSize, at height: CGFloat) -> CGSize {
            guard source.width > 0, source.height > 0 else { return CGSize(width: height, height: height) }
            let aspect = source.width / source.height
            var picture = CGSize(width: min(height, source.height) * aspect, height: min(height, source.height))
            if picture.width > maxWidth { picture = CGSize(width: maxWidth, height: maxWidth / aspect) }
            return CGSize(width: max(minimumPhotoSide, picture.width.rounded()), height: max(minimumPhotoSide, picture.height.rounded()))
        }
        func fits(_ sources: ArraySlice<CGSize>, at height: CGFloat) -> Bool {
            let used = sources.reduce(minimumGap) { $0 + size($1, at: height).width + padding + minimumGap }
            return used <= ropeLength
        }

        // The newest photos that fit at the smallest height; always at least one.
        var count = pointSizes.count
        while count > 1, !fits(pointSizes.suffix(count), at: low) { count -= 1 }
        let shown = pointSizes.suffix(count)

        // The largest height that still fits, found by halving.
        var fitting = low, tooBig = maxHeight + 1
        if fits(shown, at: maxHeight) {
            fitting = maxHeight
        } else {
            for _ in 0..<24 {
                let middle = (fitting + tooBig) / 2
                if fits(shown, at: middle) { fitting = middle } else { tooBig = middle }
            }
        }
        return shown.map { size($0, at: fitting) }
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
