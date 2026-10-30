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
    /// The smallest space left between neighboring photos, and between the end photos and the
    /// rope's ends, like pegs spaced along a real line.
    public static let minimumGap: CGFloat = 32

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
        let maxWidth = panoramaWidth(ropeLength: ropeLength)
        func size(_ source: CGSize, at height: CGFloat) -> CGSize { photoSize(source, at: height, maxWidth: maxWidth) }
        func fits(_ sources: ArraySlice<CGSize>, at height: CGFloat) -> Bool {
            Self.fits(sources, at: height, ropeLength: ropeLength, padding: padding)
        }

        // The newest photos that fit at the smallest height; always at least one.
        let shown = pointSizes.suffix(fittingCount(pointSizes: pointSizes, ropeLength: ropeLength, height: low, padding: padding))

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

    /// How many of the newest photos (`pointSizes`, oldest first) fit on one rope at `height`;
    /// always at least one.
    public static func fittingCount(pointSizes: [CGSize], ropeLength: CGFloat, height: CGFloat, padding: CGFloat = 0) -> Int {
        var count = pointSizes.count
        while count > 1, !fits(pointSizes.suffix(count), at: height, ropeLength: ropeLength, padding: padding) { count -= 1 }
        return count
    }

    /// One rope's worth of captures: a whole day, or part of a day too full for one rope.
    public struct Rope: Equatable, Sendable {
        public let title: String
        /// Oldest first.
        public let entries: [HistoryEntry]
        /// The older part of a day that started on the rope above.
        public let continued: Bool
    }

    /// `days` (newest first) laid out one rope each, except that a day whose photos don't all fit
    /// at `height` carries on, older photos first dropping to the next rope, and the next.
    public static func ropes(_ days: [HistoryGrouping.Day], ropeLength: CGFloat, height: CGFloat, padding: CGFloat = 0) -> [Rope] {
        var ropes: [Rope] = []
        for day in days {
            var remaining = day.entries[...]
            var continued = false
            while !remaining.isEmpty {
                let count = fittingCount(pointSizes: remaining.map(pointSize), ropeLength: ropeLength, height: height, padding: padding)
                ropes.append(Rope(title: day.title, entries: Array(remaining.suffix(count)), continued: continued))
                remaining = remaining.dropLast(count)
                continued = true
            }
        }
        return ropes
    }

    /// A capture's size in points.
    public static func pointSize(_ entry: HistoryEntry) -> CGSize {
        CGSize(width: CGFloat(entry.pixelWidth) / CGFloat(max(entry.scale, 1)), height: CGFloat(entry.pixelHeight) / CGFloat(max(entry.scale, 1)))
    }

    /// Panoramas don't take over the whole rope.
    private static func panoramaWidth(ropeLength: CGFloat) -> CGFloat { max(ropeLength * 0.45, minimumPhotoSide) }

    private static func photoSize(_ source: CGSize, at height: CGFloat, maxWidth: CGFloat) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: height, height: height) }
        let aspect = source.width / source.height
        var picture = CGSize(width: min(height, source.height) * aspect, height: min(height, source.height))
        if picture.width > maxWidth { picture = CGSize(width: maxWidth, height: maxWidth / aspect) }
        return CGSize(width: max(minimumPhotoSide, picture.width.rounded()), height: max(minimumPhotoSide, picture.height.rounded()))
    }

    private static func fits(_ sources: ArraySlice<CGSize>, at height: CGFloat, ropeLength: CGFloat, padding: CGFloat) -> Bool {
        let maxWidth = panoramaWidth(ropeLength: ropeLength)
        let used = sources.reduce(minimumGap) { $0 + photoSize($1, at: height, maxWidth: maxWidth).width + padding + minimumGap }
        return used <= ropeLength
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
