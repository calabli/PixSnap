import Foundation

/// Builds a long screenshot from frames of the same region taken while its content scrolls, in
/// either direction. It keeps track of where the current view sits in the long image, and finds
/// each new frame's place by sliding it along the long image near there: rows that came into view
/// below are added at the bottom, rows above at the top, and scrolling back over rows already taken
/// just moves the place. Rows are compared by hash.
///
/// Rows that stay put while the content moves (a sticky header or footer) are found the first time
/// anything moves; from then on they're set aside, kept once at the top and bottom of the result,
/// and the frames are matched on what's between them.
///
/// Frames are 8-bit RGBA, top row first, `width × 4` bytes per row.
public final class ScrollStitcher {
    public enum Outcome: Equatable {
        /// The first frame.
        case started
        /// New rows came into view at the bottom and were added.
        case added(rows: Int)
        /// New rows came into view at the top and were added there.
        case addedAbove(rows: Int)
        /// The view moved over rows already taken.
        case moved
        /// Nothing moved.
        case unchanged
        /// No place for the frame was found (scrolled too far at once): it was skipped.
        /// Scrolling back a little picks the thread up again.
        case lost
        /// The image reached `maximumHeight`; nothing more is added.
        case full
    }

    public let width: Int
    public let frameHeight: Int
    public let maximumHeight: Int

    /// Rows held still at the top and bottom of every frame, once known.
    private var header: [UInt8] = []
    private var footer: [UInt8] = []
    private var headerRows = 0
    private var footerRows = 0
    private var bandsKnown = false

    /// The scrolling content: pieces of rows, top first, so adding above doesn't copy everything.
    private var pieces: [[UInt8]] = []
    private var bodyHashes: [UInt64] = []
    /// Where the current view's first content row is in the body.
    private var place = 0
    private var last: Frame?

    public init(width: Int, frameHeight: Int, maximumHeight: Int = 40_000) {
        self.width = width
        self.frameHeight = frameHeight
        self.maximumHeight = maximumHeight
    }

    private var bytesPerRow: Int { width * 4 }

    public var height: Int { headerRows + bodyHashes.count + footerRows }

    /// The long image so far, top row first.
    public var pixels: [UInt8] {
        var all = header
        all.reserveCapacity(height * bytesPerRow)
        for piece in pieces { all.append(contentsOf: piece) }
        all.append(contentsOf: footer)
        return all
    }

    /// Takes in one frame, `frameHeight` rows of `width` RGBA pixels.
    @discardableResult
    public func add(_ bytes: [UInt8]) -> Outcome {
        precondition(bytes.count == bytesPerRow * frameHeight, "frame size doesn't match")
        let frame = Frame(bytes: bytes, width: width, height: frameHeight)
        guard let previous = last else {
            pieces = [bytes]
            bodyHashes = frame.hashes
            last = frame
            return .started
        }
        if frame.hashes == previous.hashes { return .unchanged }
        if !bandsKnown { findBands(previous: previous, next: frame) }

        let start = headerRows, count = frameHeight - headerRows - footerRows
        guard count >= 8, let offset = locate(frame, start: start, count: count) else { return .lost }
        last = frame

        if offset < 0 {
            // Rows above the top of the image came into view.
            let new = min(-offset, maximumHeight - height)
            guard new > 0 else { return .full }
            let from = (start - offset - new) * bytesPerRow
            pieces.insert(Array(bytes[from ..< from + new * bytesPerRow]), at: 0)
            bodyHashes.insert(contentsOf: frame.hashes[(start - offset - new) ..< (start - offset)], at: 0)
            place = 0
            return .addedAbove(rows: new)
        }
        let below = offset + count - bodyHashes.count
        if below > 0 {
            // Rows below the bottom of the image came into view.
            let new = min(below, maximumHeight - height)
            guard new > 0 else { return .full }
            let from = (start + count - below) * bytesPerRow
            pieces.append(Array(bytes[from ..< from + new * bytesPerRow]))
            bodyHashes.append(contentsOf: frame.hashes[(start + count - below) ..< (start + count - below + new)])
            place = offset
            return .added(rows: new)
        }
        place = offset
        return .moved
    }

    /// The first time the content moves, rows that stayed put at the top and bottom are a sticky
    /// header and footer. They're taken out of the body (which is still just the first frame).
    private func findBands(previous: Frame, next: Frame) {
        var top = 0
        while top < frameHeight, previous.hashes[top] == next.hashes[top] { top += 1 }
        var bottom = 0
        while bottom < frameHeight - top, previous.hashes[frameHeight - 1 - bottom] == next.hashes[frameHeight - 1 - bottom] { bottom += 1 }
        // Leave enough between them to match on.
        guard frameHeight - top - bottom >= 8 else { return }
        bandsKnown = true
        guard top > 0 || bottom > 0, let first = pieces.first, pieces.count == 1 else { return }
        headerRows = top
        footerRows = bottom
        header = Array(first[0 ..< top * bytesPerRow])
        footer = Array(first[(frameHeight - bottom) * bytesPerRow ..< frameHeight * bytesPerRow])
        pieces = [Array(first[top * bytesPerRow ..< (frameHeight - bottom) * bytesPerRow])]
        bodyHashes = Array(bodyHashes[top ..< frameHeight - bottom])
        place = 0
    }

    /// Where the frame's content rows (`count` of them from `start`) sit in the body: the offset of
    /// its first one, which may be above the top (negative) or run past the bottom. Only rows with
    /// something in them count (a blank row matches any other blank row), and a few may differ, for
    /// a blinking cursor or an animation. Among equally good places, the one nearest the last wins,
    /// which keeps repeating patterns like list rows from jumping.
    private func locate(_ frame: Frame, start: Int, count: Int) -> Int? {
        let minimumOverlap = max(12, count / 10)
        let lowest = max(place - count + minimumOverlap, -(count - minimumOverlap))
        let highest = min(place + count - minimumOverlap, bodyHashes.count - minimumOverlap)
        guard lowest <= highest else { return nil }
        var best: (offset: Int, ratio: Double, distance: Int)?
        for offset in lowest ... highest {
            var compared = 0, matched = 0
            for row in max(0, -offset) ..< min(count, bodyHashes.count - offset) where frame.hasContent[start + row] {
                compared += 1
                if frame.hashes[start + row] == bodyHashes[offset + row] { matched += 1 }
            }
            guard compared >= 6 else { continue }
            let ratio = Double(matched) / Double(compared)
            guard ratio >= 0.9 else { continue }
            let distance = abs(offset - place)
            if best == nil || ratio > best!.ratio + 0.0001 || (abs(ratio - best!.ratio) <= 0.0001 && distance < best!.distance) {
                best = (offset, ratio, distance)
            }
        }
        return best?.offset
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
