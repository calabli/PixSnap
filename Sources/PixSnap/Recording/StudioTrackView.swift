import AppKit
import PixSnapCore

/// 精修's timeline, on the recording's own time: the picture (cut stretches hatched, sped-up ones
/// grey with their speed), the zooms (orange; a switched-off one only outlined), each click, key
/// and mark, and the playhead. Click to jump there; drag across to select a stretch; click a zoom to
/// switch it off or on again.
@MainActor
final class StudioTrackView: NSView {
    var onSeek: ((Double) -> Void)?
    var onSelect: ((ClosedRange<Double>?) -> Void)?
    /// A zoom was clicked: the clicks it was made from.
    var onToggleZoom: (([Double]) -> Void)?

    var duration: Double = 1 { didSet { needsDisplay = true } }
    var timeline: RecordingTimeline? { didSet { needsDisplay = true } }
    /// Zooms on the recording's time, and which are switched off.
    var zooms: [(segment: ZoomPlan.Segment, on: Bool)] = [] { didSet { needsDisplay = true } }
    var edit = VideoEdit() { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }
    private(set) var selection: ClosedRange<Double>? { didSet { needsDisplay = true } }

    private var dragStart: Double?
    private var dragged = false

    private static let labelWidth: CGFloat = 52
    private static let rows: [(String, CGFloat)] = [("画面", 30), ("放大", 22), ("点击", 16), ("按键", 16)]
    private static let rowGap: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var track: CGRect { CGRect(x: Self.labelWidth, y: 24, width: bounds.width - Self.labelWidth - 14, height: bounds.height - 30) }

    private func x(_ t: Double) -> CGFloat { track.minX + CGFloat(t / max(duration, 0.01)) * track.width }
    private func time(_ x: CGFloat) -> Double { min(max(Double((x - track.minX) / max(track.width, 1)) * duration, 0), duration) }

    private func rowRect(_ index: Int) -> CGRect {
        var y = track.minY
        for row in Self.rows.prefix(index) { y += row.1 + Self.rowGap }
        return CGRect(x: track.minX, y: y, width: track.width, height: Self.rows[index].1)
    }

    func clearSelection() {
        selection = nil
        onSelect?(nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor(white: 0.6, alpha: 1)]
        // Ruler.
        let step = duration > 120 ? 30.0 : duration > 40 ? 10.0 : duration > 12 ? 5.0 : 1.0
        var t = 0.0
        while t <= duration + 0.001 {
            let label = String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) as NSString
            label.draw(at: CGPoint(x: x(t) - 2, y: 4), withAttributes: small)
            t += step
        }
        let labels: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
        for (index, row) in Self.rows.enumerated() {
            let rect = rowRect(index)
            (row.0 as NSString).draw(at: CGPoint(x: 12, y: rect.midY - 7), withAttributes: labels)
        }

        // Picture: plain, then the changes over it.
        let picture = rowRect(0)
        NSColor(white: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: picture, xRadius: 4, yRadius: 4).fill()
        for change in edit.changes {
            let rect = CGRect(x: x(change.start), y: picture.minY, width: max(2, x(change.end) - x(change.start)), height: picture.height)
            if change.isCut {
                NSColor(srgbRed: 0.75, green: 0.2, blue: 0.18, alpha: 0.85).setFill()
                rect.fill()
                NSColor(white: 0, alpha: 0.35).setStroke()
                let hatch = NSBezierPath()
                var hx = rect.minX - rect.height
                while hx < rect.maxX {
                    hatch.move(to: CGPoint(x: hx, y: rect.maxY))
                    hatch.line(to: CGPoint(x: hx + rect.height, y: rect.minY))
                    hx += 8
                }
                NSGraphicsContext.saveGraphicsState()
                rect.clip()
                hatch.lineWidth = 3
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor(white: 0.5, alpha: 1).setFill()
                rect.fill()
                let text = String(format: "%g×", change.speed) as NSString
                text.draw(at: CGPoint(x: rect.minX + 4, y: rect.midY - 7), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white])
            }
        }

        // Zooms.
        let zoomRow = rowRect(1)
        for zoom in zooms {
            let rect = CGRect(x: x(zoom.segment.start), y: zoomRow.minY, width: max(4, x(zoom.segment.end) - x(zoom.segment.start)), height: zoomRow.height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            if zoom.on {
                NSColor.systemOrange.setFill()
                shape.fill()
                (String(format: "%g×", zoom.segment.scale) as NSString).draw(
                    at: CGPoint(x: rect.minX + 5, y: rect.midY - 7),
                    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
            } else {
                NSColor.systemOrange.withAlphaComponent(0.6).setStroke()
                shape.lineWidth = 1.5
                shape.setLineDash([4, 3], count: 2, phase: 0)
                shape.stroke()
            }
        }

        // Clicks, keys, marks.
        if let timeline {
            let clickRow = rowRect(2)
            for click in timeline.clicks {
                (click.button == .right ? NSColor.systemOrange : NSColor.systemBlue).setFill()
                NSBezierPath(ovalIn: CGRect(x: x(click.t) - 4, y: clickRow.midY - 4, width: 8, height: 8)).fill()
            }
            let keyRow = rowRect(3)
            for key in timeline.keys {
                (key.label as NSString).draw(at: CGPoint(x: x(key.t) - 2, y: keyRow.minY),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            }
            NSColor.systemOrange.setFill()
            for mark in timeline.marks {
                let flag = NSBezierPath()
                let fx = x(mark)
                flag.move(to: CGPoint(x: fx, y: clickRow.minY))
                flag.line(to: CGPoint(x: fx + 9, y: clickRow.minY + 4))
                flag.line(to: CGPoint(x: fx, y: clickRow.minY + 8))
                flag.close()
                flag.fill()
            }
        }

        // Selection and playhead.
        if let selection {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            CGRect(x: x(selection.lowerBound), y: track.minY - 4, width: x(selection.upperBound) - x(selection.lowerBound), height: track.height + 4).fill()
        }
        NSColor.white.setFill()
        CGRect(x: x(playhead) - 1, y: track.minY - 6, width: 2, height: track.height + 6).fill()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A click on a zoom switches it.
        if rowRect(1).insetBy(dx: 0, dy: -2).contains(point),
           let zoom = zooms.first(where: { x($0.segment.start) <= point.x && point.x <= x($0.segment.end) }) {
            onToggleZoom?(zoom.segment.focus.map(\.t))
            return
        }
        dragStart = time(point.x)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = time(convert(event.locationInWindow, from: nil).x)
        guard abs(now - start) > duration / max(Double(track.width), 1) * 3 else { return }
        dragged = true
        selection = min(start, now) ... max(start, now)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let start = dragStart else { return }
        if dragged {
            onSelect?(selection)
        } else {
            selection = nil
            onSelect?(nil)
            onSeek?(start)
        }
    }
}
