import Foundation

/// A box in a recording to cover with mosaic (a password, a phone number, someone's name), and
/// when: fractions of the frame from the top-left, and seconds of the recording.
public struct MosaicRegion: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), x: Double, y: Double, width: Double, height: Double, start: Double, end: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.start = start
        self.end = end
    }

    /// Kept inside the frame and at least a little box.
    public func clamped() -> MosaicRegion {
        var region = self
        region.width = min(max(width, 0.01), 1)
        region.height = min(max(height, 0.01), 1)
        region.x = min(max(x, 0), 1 - region.width)
        region.y = min(max(y, 0), 1 - region.height)
        return region
    }

    public func isShowing(at t: Double) -> Bool { t >= start && t <= end }
}

/// What 精修 did to a recording, kept beside it (`<video>.studio.json`) so it's there next time:
/// the cuts and speed-ups, the zooms switched off (by the time of their clicks) and the mosaics.
public struct StudioProject: Codable, Equatable, Sendable {
    public var changes: [VideoEdit.Change] = []
    public var disabledClicks: [Double] = []
    public var mosaics: [MosaicRegion] = []

    public init(changes: [VideoEdit.Change] = [], disabledClicks: [Double] = [], mosaics: [MosaicRegion] = []) {
        self.changes = changes
        self.disabledClicks = disabledClicks
        self.mosaics = mosaics
    }

    public var isEmpty: Bool { changes.isEmpty && disabledClicks.isEmpty && mosaics.isEmpty }

    /// After the recording itself was trimmed to `start`…`end`: times counted from the new start,
    /// what fell outside dropped.
    public func trimmed(from start: Double, to end: Double) -> StudioProject {
        var result = StudioProject()
        result.changes = changes.compactMap { change in
            let s = max(change.start, start), e = min(change.end, end)
            return e - s >= 0.1 ? VideoEdit.Change(start: s - start, end: e - start, speed: change.speed) : nil
        }
        result.disabledClicks = disabledClicks.filter { $0 >= start && $0 <= end }.map { $0 - start }
        result.mosaics = mosaics.compactMap { region in
            let s = max(region.start, start), e = min(region.end, end)
            guard e > s else { return nil }
            var moved = region
            moved.start = s - start
            moved.end = e - start
            return moved
        }
        return result
    }

    /// The mosaics on the edited video's time: a start or end inside a cut moves to where the cut
    /// was; one wholly inside a cut is gone.
    public func mosaics(editedBy edit: VideoEdit, duration: Double) -> [MosaicRegion] {
        func place(_ t: Double, end: Bool) -> Double {
            if let time = edit.editedTime(t, duration: duration) { return time }
            let cut = edit.changes.first { $0.isCut && $0.start <= t && t <= $0.end }
            return edit.editedTime(cut?.start ?? t, duration: duration) ?? 0
        }
        return mosaics.compactMap { region in
            var moved = region
            moved.start = place(region.start, end: false)
            moved.end = place(region.end, end: true)
            return moved.end > moved.start ? moved : nil
        }
    }
}
