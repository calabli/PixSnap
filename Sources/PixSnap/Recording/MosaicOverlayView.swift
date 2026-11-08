import AppKit
import PixSnapCore
import PixSnapRender

/// Over 精修's picture while it's paused: the mosaic boxes showing at that moment, outlined. Drag on
/// the picture to draw a new one (after 添加打码), drag a box to move it, its corner to resize it,
/// ⌫ or its × to remove it. Clicks anywhere else go through to the player.
@MainActor
final class MosaicOverlayView: NSView {
    /// Where the picture is drawn in this view, and how the recording sits in it.
    var videoRect: CGRect = .zero { didSet { needsDisplay = true } }
    var outputSize = CGSize(width: 1, height: 1)
    var placement: RecordingFinisher.Placement? { didSet { needsDisplay = true } }
    /// The boxes showing now (on the recording's time, as they're kept).
    var regions: [MosaicRegion] = [] { didSet { needsDisplay = true } }
    var selected: UUID? { didSet { needsDisplay = true } }
    /// Drawing a new box on the next drag.
    var drawing = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var onCreate: ((CGRect) -> Void)?
    var onChange: ((MosaicRegion) -> Void)?
    var onSelect: ((UUID?) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private enum Drag { case create(CGPoint), move(MosaicRegion, CGPoint), resize(MosaicRegion) }
    private var drag: Drag?
    private var draft: CGRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    /// A spot of the recording (fractions) to this view, and back.
    private func view(x: Double, y: Double) -> CGPoint? {
        guard let placement, outputSize.width > 0 else { return nil }
        let out = placement.output(x: x, y: y)
        return CGPoint(x: videoRect.minX + out.x / outputSize.width * videoRect.width, y: videoRect.minY + out.y / outputSize.height * videoRect.height)
    }

    private func source(_ point: CGPoint) -> (x: Double, y: Double)? {
        guard let placement, videoRect.width > 0 else { return nil }
        let out = CGPoint(x: (point.x - videoRect.minX) / videoRect.width * outputSize.width, y: (point.y - videoRect.minY) / videoRect.height * outputSize.height)
        return placement.source(out)
    }

    private func rect(of region: MosaicRegion) -> CGRect? {
        guard let a = view(x: region.x, y: region.y), let b = view(x: region.x + region.width, y: region.y + region.height) else { return nil }
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    private func closeButton(of rect: CGRect) -> CGRect { CGRect(x: rect.maxX - 9, y: rect.minY - 9, width: 18, height: 18) }
    private func handle(of rect: CGRect) -> CGRect { CGRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 12, height: 12) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if drawing {
            NSColor(white: 0, alpha: 0.15).setFill()
            videoRect.fill()
            let hint = "拖出一个框，盖住要打码的地方" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attributes)
            let pill = CGRect(x: videoRect.midX - size.width / 2 - 12, y: videoRect.minY + 14, width: size.width + 24, height: size.height + 10)
            NSColor(white: 0, alpha: 0.7).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            hint.draw(at: CGPoint(x: pill.minX + 12, y: pill.minY + 5), withAttributes: attributes)
        }
        for region in regions {
            guard let rect = rect(of: region) else { continue }
            let isSelected = region.id == selected
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = isSelected ? 2 : 1.5
            if !isSelected { outline.setLineDash([5, 3], count: 2, phase: 0) }
            NSColor.systemPurple.setStroke()
            outline.stroke()
            if isSelected {
                NSColor.white.setFill()
                NSColor.systemPurple.setStroke()
                let knob = NSBezierPath(ovalIn: handle(of: rect))
                knob.fill()
                knob.stroke()
                let close = closeButton(of: rect)
                NSColor.systemPurple.setFill()
                NSBezierPath(ovalIn: close).fill()
                let cross = NSBezierPath()
                cross.move(to: CGPoint(x: close.minX + 6, y: close.minY + 6))
                cross.line(to: CGPoint(x: close.maxX - 6, y: close.maxY - 6))
                cross.move(to: CGPoint(x: close.maxX - 6, y: close.minY + 6))
                cross.line(to: CGPoint(x: close.minX + 6, y: close.maxY - 6))
                cross.lineWidth = 1.5
                NSColor.white.setStroke()
                cross.stroke()
            }
        }
        if let draft {
            NSColor.systemPurple.withAlphaComponent(0.25).setFill()
            draft.fill()
            NSColor.systemPurple.setStroke()
            NSBezierPath(rect: draft).stroke()
        }
    }

    override func resetCursorRects() {
        if drawing { addCursorRect(videoRect, cursor: .crosshair) }
    }

    // MARK: Mouse

    /// Only the boxes (and the picture while drawing) take clicks; the rest is the player's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if drawing, videoRect.contains(local) { return self }
        for region in regions {
            guard let rect = rect(of: region) else { continue }
            if rect.insetBy(dx: -8, dy: -8).contains(local) || (region.id == selected && closeButton(of: rect).contains(local)) { return self }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if drawing {
            drag = .create(point)
            return
        }
        // The selected box's × and corner first, then any box (the top one).
        if let id = selected, let region = regions.first(where: { $0.id == id }), let rect = rect(of: region) {
            if closeButton(of: rect).contains(point) {
                onDelete?(id)
                return
            }
            if handle(of: rect).insetBy(dx: -4, dy: -4).contains(point) {
                drag = .resize(region)
                return
            }
        }
        if let region = regions.last(where: { rect(of: $0)?.insetBy(dx: -8, dy: -8).contains(point) ?? false }) {
            selected = region.id
            onSelect?(region.id)
            drag = .move(region, point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .create(start):
            draft = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                .intersection(videoRect)
            needsDisplay = true
        case let .move(region, start):
            guard let from = source(start), let to = source(point) else { return }
            var moved = region
            moved.x += to.x - from.x
            moved.y += to.y - from.y
            update(moved.clamped())
        case let .resize(region):
            guard let corner = source(point) else { return }
            var resized = region
            resized.width = corner.x - region.x
            resized.height = corner.y - region.y
            update(resized.clamped())
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard case .create = drag else { return }
        drawing = false
        defer {
            draft = nil
            needsDisplay = true
        }
        guard let draft, draft.width > 6, draft.height > 6,
              let a = source(CGPoint(x: draft.minX, y: draft.minY)), let b = source(CGPoint(x: draft.maxX, y: draft.maxY)) else { return }
        onCreate?(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
    }

    private func update(_ region: MosaicRegion) {
        if let index = regions.firstIndex(where: { $0.id == region.id }) { regions[index] = region }
        onChange?(region)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, let selected {
            onDelete?(selected)
        } else if event.keyCode == 53 {
            drawing = false
            selected = nil
            onSelect?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
