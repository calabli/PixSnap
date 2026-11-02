import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 时光胶片: all of history on one strip of film, oldest at the left and newest at the right, each
/// day starting with a marker printed on the film edge.
public enum FilmStrip {
    public enum Item: Equatable, Sendable {
        /// The start of a day: its title ("今天", "10月25日") and how many captures it has.
        case day(String, count: Int)
        case frame(HistoryEntry)
    }

    /// `entries` in any order, as the strip: oldest day first, each day's marker then its captures,
    /// oldest first.
    public static func items(_ entries: [HistoryEntry], now: Date, calendar: Calendar = .current) -> [Item] {
        HistoryGrouping.days(entries, now: now, calendar: calendar, limit: .max).reversed().flatMap { day in
            [Item.day(day.title, count: day.entries.count)] + day.entries.map(Item.frame)
        }
    }

    /// Widest and narrowest a frame gets, against its height: panoramas and long screenshots don't
    /// take over the strip or shrink to a sliver.
    public static let aspectRange: ClosedRange<Double> = 0.45 ... 2.4

    /// How wide a capture's picture is on a strip whose frames are `height` tall.
    public static func pictureWidth(pixelWidth: Int, pixelHeight: Int, height: CGFloat) -> CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return height }
        let aspect = min(max(Double(pixelWidth) / Double(pixelHeight), aspectRange.lowerBound), aspectRange.upperBound)
        return (height * CGFloat(aspect)).rounded()
    }

    /// Where the sprocket holes start in a piece of film whose left edge is at `x` on the strip, so
    /// the holes line up from one piece to the next: holes every `pitch` points from the strip's start.
    public static func sprocketPhase(atX x: CGFloat, pitch: CGFloat) -> CGFloat {
        let remainder = x.truncatingRemainder(dividingBy: pitch)
        return remainder == 0 ? 0 : pitch - remainder
    }
}
