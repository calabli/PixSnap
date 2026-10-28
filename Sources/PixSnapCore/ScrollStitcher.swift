import Foundation

/// Builds a long screenshot from frames of the same region taken while its content scrolls down.
/// Each frame is compared with the last one taken in: rows are hashed, rows that didn't move at the
/// top and bottom (a sticky header or footer) are set aside, and the middle is slid against the last
/// frame to find how far the content moved. The rows that came into view are added before the
/// footer, so a sticky header appears once at the top and a sticky footer once at the bottom.
///
/// Frames are 8-bit RGBA, top row first, `width × 4` bytes per row.
public final class ScrollStitcher {
    public enum Outcome: Equatable {
        /// The first frame.
        case started
        /// The content moved down by this many rows, which were added.
        case added(rows: Int)
        /// Nothing moved.
        case unchanged
        /// No overlap with the last frame was found (scrolled too far at once, or up): the frame
        /// was skipped. Scrolling back a little picks the thread up again.
        case lost
        /// The image reached `maximumHeight`; nothing more is added.
        case full
    }

    public let width: Int
    public let frameHeight: Int
    public let maximumHeight: Int
    /// The long image so far, top row first.
    public private(set) var pixels: [UInt8] = []
    public var height: Int { pixels.count / bytesPerRow }

    private var bytesPerRow: Int { width * 4 }
    /// The last frame taken in; the stitched image always ends with its rows.
    private var reference: Frame?

    public init(width: Int, frameHeight: Int, maximumHeight: Int = 40_000) {
        self.width = width
        self.frameHeight = frameHeight
        self.maximumHeight = maximumHeight
    }

    /// Takes in one frame, `frameHeight` rows of `width` RGBA pixels.
    @discardableResult
    public func add(_ bytes: [UInt8]) -> Outcome {
        precondition(bytes.count == bytesPerRow * frameHeight, "frame size doesn't match")
        let frame = Frame(bytes: bytes, width: width, height: frameHeight)
        guard let last = reference else {
            pixels = bytes
            reference = frame
            return .started
        }
        guard height < maximumHeight else { return .full }

        let rows = frameHeight
        // Rows that stayed put: a sticky header from the top, a sticky footer from the bottom.
        var header = 0
        while header < rows, last.hashes[header] == frame.hashes[header] { header += 1 }
        if header == rows { return .unchanged }
        var footer = 0
        while footer < rows - header, last.hashes[rows - 1 - footer] == frame.hashes[rows - 1 - footer] { footer += 1 }
        // Blank rows at the edges of moving content look like they stayed put too; keep enough
        // middle to match on.
        let middle = rows - header - footer
        guard middle >= 8, let shift = Self.shift(from: last, to: frame, start: header, count: middle) else { return .lost }

        // The image ends with the last frame's rows: drop its footer, add what came into view
        // and the footer again.
        let added = min(shift, maximumHeight - height)
        pixels.removeLast(footer * bytesPerRow)
        let from = (header + middle - shift) * bytesPerRow
        pixels.append(contentsOf: bytes[from ..< from + added * bytesPerRow])
        pixels.append(contentsOf: bytes[(rows - footer) * bytesPerRow ..< rows * bytesPerRow])
        reference = frame
        return .added(rows: added)
    }

    /// How many rows the middle band moved up from `last` to `next`, if they overlap. Only rows with
    /// something in them count (a blank row matches any other blank row), and a few may differ, for
    /// a blinking cursor or an animation.
    private static func shift(from last: Frame, to next: Frame, start: Int, count: Int) -> Int? {
        let minimumOverlap = max(12, count / 10)
        var best: (shift: Int, ratio: Double, compared: Int)?
        for shift in 1 ... max(1, count - minimumOverlap) {
            let overlap = count - shift
            var compared = 0, matched = 0
            for row in 0 ..< overlap where next.hasContent[start + row] {
                compared += 1
                if next.hashes[start + row] == last.hashes[start + row + shift] { matched += 1 }
            }
            guard compared >= 6 else { continue }
            let ratio = Double(matched) / Double(compared)
            guard ratio >= 0.9 else { continue }
            // The best match wins; on a tie, the one that compared more rows (the smaller move),
            // which keeps repeating patterns like list rows from jumping ahead.
            if best == nil || ratio > best!.ratio + 0.0001 || (abs(ratio - best!.ratio) <= 0.0001 && compared > best!.compared) {
                best = (shift, ratio, compared)
            }
        }
        return best?.shift
    }

    /// A frame's rows, hashed for comparing.
    private struct Frame {
        let hashes: [UInt64]
        /// Whether a row has more than one color in it.
        let hasContent: [Bool]

        init(bytes: [UInt8], width: Int, height: Int) {
            var hashes = [UInt64](repeating: 0, count: height)
            var hasContent = [Bool](repeating: false, count: height)
            bytes.withUnsafeBytes { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for row in 0 ..< height {
                    let start = row * width
                    // FNV-1a over the row's pixels.
                    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                    let first = words[start]
                    var varied = false
                    for column in 0 ..< width {
                        let pixel = words[start + column]
                        hash = (hash ^ UInt64(pixel)) &* 0x0000_0100_0000_01b3
                        if pixel != first { varied = true }
                    }
                    hashes[row] = hash
                    hasContent[row] = varied
                }
            }
            self.hashes = hashes
            self.hasContent = hasContent
        }
    }
}
