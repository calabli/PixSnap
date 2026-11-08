import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What happened while a recording was made, kept beside the video (`<id>.timeline.json`): where
/// the pointer went, each click (and the name of what was clicked), shortcuts, and the steps marked
/// with ⌥⇧M. Times are seconds into the video (pauses left out); positions are fractions of the
/// recorded region, from its top-left corner, and may fall outside 0…1 when the pointer left it.
/// Zoom, a polished pointer and the step-by-step guide are all made from it afterwards, so they can
/// change without recording again.
public struct RecordingTimeline: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double

        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }
    }

    public struct Click: Codable, Equatable, Sendable {
        public enum Button: String, Codable, Sendable { case left, right, other }

        public var t: Double
        public var x: Double
        public var y: Double
        public var button: Button
        /// 2 for a double-click.
        public var count: Int
        /// What was under the pointer, as the system names it ("隐私与安全性"), when PixSnap may ask.
        public var element: String?
        /// The app in front.
        public var app: String?

        public init(t: Double, x: Double, y: Double, button: Button = .left, count: Int = 1, element: String? = nil, app: String? = nil) {
            self.t = t
            self.x = x
            self.y = y
            self.button = button
            self.count = count
            self.element = element
            self.app = app
        }
    }

    public struct Key: Codable, Equatable, Sendable {
        public var t: Double
        /// As `Keystroke` writes it ("⌘F", "↩"); plain typing is never kept.
        public var label: String

        public init(t: Double, label: String) {
            self.t = t
            self.label = label
        }
    }

    /// The recorded region's size in points.
    public var width: Double
    public var height: Double
    public var moves: [Point] = []
    public var clicks: [Click] = []
    public var keys: [Key] = []
    /// Steps marked by hand, as times.
    public var marks: [Double] = []

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Where the pointer was at `t`, between the samples either side; nil before the first.
    public func pointer(at t: Double) -> Point? {
        guard let first = moves.first, t >= first.t else { return nil }
        var low = 0, high = moves.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if moves[middle].t <= t { low = middle } else { high = middle - 1 }
        }
        let before = moves[low]
        guard low + 1 < moves.count else { return before }
        let after = moves[low + 1]
        let span = after.t - before.t
        let progress = span > 0 ? (t - before.t) / span : 0
        return Point(t: t, x: before.x + (after.x - before.x) * progress, y: before.y + (after.y - before.y) * progress)
    }

    /// The same timeline for the part of the video from `start` to `end`, times counted from `start`
    /// (after trimming).
    public func trimmed(from start: Double, to end: Double) -> RecordingTimeline {
        var cut = RecordingTimeline(width: width, height: height)
        cut.moves = moves.filter { $0.t >= start && $0.t <= end }.map { Point(t: $0.t - start, x: $0.x, y: $0.y) }
        cut.clicks = clicks.filter { $0.t >= start && $0.t <= end }.map {
            var click = $0
            click.t -= start
            return click
        }
        cut.keys = keys.filter { $0.t >= start && $0.t <= end }.map { Key(t: $0.t - start, label: $0.label) }
        cut.marks = marks.filter { $0 >= start && $0 <= end }.map { $0 - start }
        return cut
    }
}

/// 跟随放大: when and where the picture zooms in, planned from the clicks. Each click zooms in a
/// little before it and holds a while after; clicks close together share one zoom that glides from
/// one to the next, so the picture doesn't bounce in and out.
public struct ZoomPlan: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var scale: Double
        /// Where to look, and from when: the clicks inside it.
        public var focus: [RecordingTimeline.Point]

        public init(start: Double, end: Double, scale: Double, focus: [RecordingTimeline.Point]) {
            self.start = start
            self.end = end
            self.scale = scale
            self.focus = focus
        }
    }

    public var segments: [Segment]

    /// How long zooming in or out takes.
    public static let transition = 0.45
    /// How long before a click the zoom starts arriving.
    public static let lead = 0.35

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// `scale` 1.5–3; `hold`, seconds to stay in after the last click of a run. Clicks starting less
    /// than `gap` seconds after the previous zoom would end join it.
    public init(clicks: [RecordingTimeline.Click], scale: Double, hold: Double, gap: Double = 0.8) {
        var segments: [Segment] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            let point = RecordingTimeline.Point(t: click.t, x: min(max(click.x, 0), 1), y: min(max(click.y, 0), 1))
            let start = max(0, click.t - Self.lead - Self.transition)
            let end = click.t + hold + Self.transition
            if var last = segments.last, start <= last.end + gap {
                last.end = max(last.end, end)
                last.focus.append(point)
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(start: start, end: end, scale: scale, focus: [point]))
            }
        }
        self.segments = segments
    }

    /// How far in, and centered where (fractions of the frame, top-left origin), at time `t`.
    public func state(at t: Double) -> (scale: Double, centerX: Double, centerY: Double) {
        guard let segment = segments.first(where: { t >= $0.start && t <= $0.end }), let first = segment.focus.first else {
            return (1, 0.5, 0.5)
        }
        // In and out.
        let inProgress = Self.ease((t - segment.start) / Self.transition)
        let outProgress = Self.ease((segment.end - t) / Self.transition)
        let amount = min(inProgress, outProgress)
        let scale = 1 + (segment.scale - 1) * amount
        // From one click to the next, gliding over the half-second before each.
        var x = first.x, y = first.y
        for (previous, next) in zip(segment.focus, segment.focus.dropFirst()) {
            let glide = Self.ease((t - (next.t - 0.5)) / 0.5)
            guard glide > 0 else { break }
            x = previous.x + (next.x - previous.x) * glide
            y = previous.y + (next.y - previous.y) * glide
        }
        // Zooming in from the whole frame, the center moves out from the middle too.
        return (scale, 0.5 + (x - 0.5) * amount, 0.5 + (y - 0.5) * amount)
    }

    /// The part of a frame `width` × `height` shown at time `t`, top-left origin, kept inside the frame.
    public func visibleRect(at t: Double, width: Double, height: Double) -> CGRect {
        let state = state(at: t)
        let w = width / state.scale, h = height / state.scale
        let x = min(max(state.centerX * width - w / 2, 0), width - w)
        let y = min(max(state.centerY * height - h / 2, 0), height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Smooth start and stop, clamped to 0…1.
    static func ease(_ value: Double) -> Double {
        let p = min(max(value, 0), 1)
        return p * p * (3 - 2 * p)
    }
}

/// 图文教程: the steps of a recording, one per click (a double-click is one), shortcut and mark,
/// in order, each with a title made from what was clicked or pressed.
public enum StepGuide {
    public struct Step: Equatable, Sendable {
        public var t: Double
        /// Where to point, as fractions of the frame from its top-left; nil for a key or a mark.
        public var x: Double?
        public var y: Double?
        public var title: String

        public init(t: Double, x: Double?, y: Double?, title: String) {
            self.t = t
            self.x = x
            self.y = y
            self.title = title
        }
    }

    public static func steps(from timeline: RecordingTimeline) -> [Step] {
        var steps: [Step] = []
        var lastClick: RecordingTimeline.Click?
        for click in timeline.clicks.sorted(by: { $0.t < $1.t }) {
            // The second click of a double-click, or a click on the same spot right after, is the same step.
            if let last = lastClick, click.t - last.t < 0.5, abs(click.x - last.x) < 0.02, abs(click.y - last.y) < 0.02 {
                if click.count >= 2, let index = steps.lastIndex(where: { $0.t == last.t }) {
                    steps[index].title = title(for: click)
                }
                continue
            }
            lastClick = click
            steps.append(Step(t: click.t, x: min(max(click.x, 0), 1), y: min(max(click.y, 0), 1), title: title(for: click)))
        }
        for key in timeline.keys {
            steps.append(Step(t: key.t, x: nil, y: nil, title: "按 " + Keystroke.spelledOut(key.label)))
        }
        for mark in timeline.marks {
            steps.append(Step(t: mark, x: nil, y: nil, title: "这一步"))
        }
        return steps.sorted { $0.t < $1.t }
    }

    static func title(for click: RecordingTimeline.Click) -> String {
        let verb = click.button == .right ? "右键点击" : click.count >= 2 ? "双击" : "点击"
        guard let element = click.element, !element.isEmpty else { return verb + "这里" }
        return "\(verb)“\(element)”"
    }

    /// The guide as Markdown, each step's picture beside it as `images/<n>.png`.
    public static func markdown(title: String, steps: [Step]) -> String {
        var lines = ["# \(title)", ""]
        for (index, step) in steps.enumerated() {
            lines.append("## \(index + 1). \(step.title)")
            lines.append("")
            lines.append("![第 \(index + 1) 步](images/\(index + 1).png)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
