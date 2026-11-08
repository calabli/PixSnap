import Foundation

/// 精修's cuts and speed-ups, on the recording's own time: stretches taken out, and stretches
/// played faster (waiting for something to load). The finished video's time and the recording's
/// map both ways, so zooms, clicks and keys stay where they happened.
public struct VideoEdit: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var start: Double
        public var end: Double
        /// 0 takes the stretch out; above 1 plays it that many times faster.
        public var speed: Double

        public init(start: Double, end: Double, speed: Double) {
            self.start = start
            self.end = end
            self.speed = speed
        }

        public var isCut: Bool { speed <= 0 }
    }

    /// In time order, never overlapping.
    public private(set) var changes: [Change] = []

    public init(changes: [Change] = []) {
        for change in changes { apply(change) }
    }

    /// Adds a change, replacing whatever the stretch had before. Shorter than a tenth of a second
    /// does nothing.
    public mutating func apply(_ change: Change) {
        guard change.end - change.start >= 0.1 else { return }
        clear(from: change.start, to: change.end)
        changes.append(change)
        changes.sort { $0.start < $1.start }
    }

    /// Back to normal from `start` to `end`: changes there are cut short or split.
    public mutating func clear(from start: Double, to end: Double) {
        var kept: [Change] = []
        for change in changes {
            if change.end <= start || change.start >= end {
                kept.append(change)
                continue
            }
            if change.start < start { kept.append(Change(start: change.start, end: start, speed: change.speed)) }
            if change.end > end { kept.append(Change(start: end, end: change.end, speed: change.speed)) }
        }
        changes = kept.filter { $0.end - $0.start >= 0.05 }.sorted { $0.start < $1.start }
    }

    /// A piece of the recording and how it plays: in order, covering 0…`duration`.
    public struct Piece: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var speed: Double
    }

    public func pieces(duration: Double) -> [Piece] {
        var pieces: [Piece] = []
        var cursor = 0.0
        for change in changes where change.start < duration {
            if change.start > cursor { pieces.append(Piece(start: cursor, end: change.start, speed: 1)) }
            pieces.append(Piece(start: max(change.start, cursor), end: min(change.end, duration), speed: change.speed))
            cursor = min(change.end, duration)
        }
        if cursor < duration { pieces.append(Piece(start: cursor, end: duration, speed: 1)) }
        return pieces.filter { $0.end > $0.start }
    }

    /// How long the finished video is.
    public func editedDuration(of duration: Double) -> Double {
        pieces(duration: duration).reduce(0) { $0 + ($1.speed <= 0 ? 0 : ($1.end - $1.start) / $1.speed) }
    }

    /// Where recording time `t` lands in the finished video; nil inside a cut.
    public func editedTime(_ t: Double, duration: Double) -> Double? {
        var edited = 0.0
        for piece in pieces(duration: max(duration, t)) {
            if t < piece.start { break }
            if t <= piece.end {
                if piece.speed <= 0 { return nil }
                return edited + (t - piece.start) / piece.speed
            }
            edited += piece.speed <= 0 ? 0 : (piece.end - piece.start) / piece.speed
        }
        return edited
    }

    /// The recording time shown at finished time `edited`.
    public func originalTime(_ edited: Double, duration: Double) -> Double {
        var remaining = edited
        for piece in pieces(duration: duration) where piece.speed > 0 {
            let length = (piece.end - piece.start) / piece.speed
            if remaining <= length { return piece.start + remaining * piece.speed }
            remaining -= length
        }
        return duration
    }
}

public extension RecordingTimeline {
    /// The timeline on the finished video's time: events in cut stretches dropped, the rest moved.
    func edited(by edit: VideoEdit, duration: Double) -> RecordingTimeline {
        guard !edit.changes.isEmpty else { return self }
        var result = RecordingTimeline(width: width, height: height)
        result.moves = moves.compactMap { point in edit.editedTime(point.t, duration: duration).map { Point(t: $0, x: point.x, y: point.y) } }
        result.clicks = clicks.compactMap { click in
            edit.editedTime(click.t, duration: duration).map { t in
                var moved = click
                moved.t = t
                return moved
            }
        }
        result.keys = keys.compactMap { key in edit.editedTime(key.t, duration: duration).map { Key(t: $0, label: key.label) } }
        result.marks = marks.compactMap { edit.editedTime($0, duration: duration) }
        return result
    }
}
