import AppKit
import PixSnapCore
import PixSnapRender

/// Shows the screenshot with its annotations and turns mouse and keyboard input into edits.
/// Coordinates: the view is flipped, and canvas point = view point / zoom.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    var tool: EditorTool = .arrow {
        didSet {
            endTextEditing()
            if tool != .select { selectedID = nil }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: AnnotationColor = .red
    var strokeWidth: StrokeWidth = .medium

    /// Called after every committed edit, undo or redo, so the toolbar can refresh.
    var onHistoryChange: (() -> Void)?
    /// Called when a single-key shortcut picks a tool.
    var onToolShortcut: ((EditorTool) -> Void)?
    /// Called when Esc is pressed with nothing selected.
    var onEscape: (() -> Void)?
    /// Called on a double-click that doesn't hit any annotation.
    var onDoubleClick: (() -> Void)?

    /// Floating captures show only the cropped result; the editor shows the whole canvas with the crop dimmed.
    var showsOnlyOutput = false
    /// With the select tool, dragging empty space moves the window (used by floating captures).
    var dragsWindowWhenIdle = false

    private(set) var history: EditHistory<AnnotationDocument>
    private let base: CGImage
    private let scale: CGFloat
    private lazy var pixelated: CGImage? = AnnotationRenderer.pixelated(base, scale: scale)

    /// The document while a drag is in progress; committed as one undo step on mouse up.
    private var transient: AnnotationDocument?
    private var selectedID: Annotation.ID?
    private var drag: Drag?

    private var textField: NSTextField?
    private var editingText: Annotation?

    private enum Drag {
        case create(id: Annotation.ID, from: CGPoint)
        case move(original: Annotation, from: CGPoint)
        case crop(from: CGPoint)
    }

    /// Pass `history` to continue editing annotations made elsewhere (floating capture ↔ editor).
    init(capture: Capture, history: EditHistory<AnnotationDocument>? = nil) {
        self.base = capture.image
        self.scale = capture.scale
        self.history = history ?? EditHistory(AnnotationDocument(canvasSize: capture.pointSize))
        super.init(frame: CGRect(origin: .zero, size: capture.pointSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var document: AnnotationDocument { transient ?? history.current }
    /// The part of the canvas this view shows, in canvas points.
    private var visibleCanvas: CGRect { showsOnlyOutput ? history.current.outputRect : history.current.canvasRect }
    private var zoom: CGFloat { bounds.width / max(visibleCanvas.width, 1) }

    // MARK: Public actions

    func undo() {
        endTextEditing()
        history.undo()
        historyDidChange()
    }

    func redo() {
        endTextEditing()
        history.redo()
        historyDidChange()
    }

    func deleteSelection() {
        guard let selectedID else { return }
        history.apply { $0.remove(id: selectedID) }
        self.selectedID = nil
        historyDidChange()
    }

    /// Restyles the selected annotation with the current color and stroke width.
    func applyStyleToSelection() {
        guard let selectedID, var annotation = history.current.annotation(withID: selectedID) else { return }
        annotation.color = color
        annotation.lineWidth = strokeWidth.lineWidth
        if case .text(let string, let frame, _) = annotation.shape {
            let size = AnnotationRenderer.textSize(string, fontSize: strokeWidth.fontSize)
            annotation.shape = .text(string, frame: CGRect(origin: frame.origin, size: size), fontSize: strokeWidth.fontSize)
        }
        history.apply { $0.update(annotation) }
        historyDidChange()
    }

    func renderedImage() -> CGImage? {
        endTextEditing()
        return AnnotationRenderer.render(history.current, base: base, pixelated: pixelated, scale: scale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let document = self.document
        let visible = visibleCanvas
        context.saveGState()
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        AnnotationRenderer.draw(
            document,
            base: base,
            pixelated: document.annotations.contains(where: { if case .mosaic = $0.shape { true } else { false } }) ? pixelated : nil,
            in: context,
            hiding: editingText?.id
        )
        context.restoreGState()

        if !showsOnlyOutput, let crop = document.crop { drawCropOverlay(crop) }
        if let selectedID, let selected = document.annotation(withID: selectedID) { drawSelection(selected.bounds) }
    }

    private func drawCropOverlay(_ crop: CGRect) {
        let rect = viewRect(crop)
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(rect: rect))
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        mask.fill()

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        border.stroke()
    }

    private func drawSelection(_ bounds: CGRect) {
        let outline = NSBezierPath(rect: viewRect(bounds).insetBy(dx: -5, dy: -5))
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }

    private func viewRect(_ canvasRect: CGRect) -> CGRect {
        let visible = visibleCanvas
        return CGRect(
            x: (canvasRect.minX - visible.minX) * zoom,
            y: (canvasRect.minY - visible.minY) * zoom,
            width: canvasRect.width * zoom,
            height: canvasRect.height * zoom
        )
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .select: dragsWindowWhenIdle ? .openHand : .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let visible = visibleCanvas
        return CGPoint(
            x: min(max(point.x / zoom + visible.minX, visible.minX), visible.maxX),
            y: min(max(point.y / zoom + visible.minY, visible.minY), visible.maxY)
        )
    }

    override func mouseDown(with event: NSEvent) {
        endTextEditing()
        window?.makeFirstResponder(self)
        let point = canvasPoint(event)
        let hit = history.current.annotation(at: point, tolerance: 6 / zoom)

        if event.clickCount == 2, let hit, case .text = hit.shape, tool == .select || tool == .text {
            beginTextEditing(hit)
            return
        }
        if event.clickCount == 2, hit == nil, tool == .select {
            onDoubleClick?()
            return
        }

        switch tool {
        case .select:
            selectedID = hit?.id
            if let hit {
                drag = .move(original: hit, from: point)
            } else if dragsWindowWhenIdle {
                needsDisplay = true
                window?.performDrag(with: event)
                return
            }
        case .rectangle, .arrow, .mosaic:
            drag = .create(id: UUID(), from: point)
        case .crop:
            drag = .crop(from: point)
        case .text:
            if let hit, case .text = hit.shape {
                beginTextEditing(hit)
            } else {
                let fontSize = strokeWidth.fontSize
                let origin = CGPoint(x: point.x, y: point.y - fontSize * 0.6)
                beginTextEditing(Annotation(
                    shape: .text("", frame: CGRect(origin: origin, size: .zero), fontSize: fontSize),
                    color: color,
                    lineWidth: strokeWidth.lineWidth
                ))
            }
        case .counter:
            history.apply {
                $0.add(Annotation(shape: .counter($0.nextCounterNumber, center: point), color: color, lineWidth: strokeWidth.lineWidth))
            }
            historyDidChange()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = canvasPoint(event)
        var document = history.current

        switch drag {
        case .create(let id, let from):
            let rect = SelectionGeometry.rect(from: from, to: point)
            let shape: AnnotationShape? = switch tool {
            case .rectangle where SelectionGeometry.isDrag(rect): .rectangle(rect)
            case .mosaic where SelectionGeometry.isDrag(rect): .mosaic(rect)
            case .arrow where hypot(point.x - from.x, point.y - from.y) >= SelectionGeometry.minimumDragSize: .arrow(from: from, to: point)
            default: nil
            }
            guard let shape else {
                transient = nil
                needsDisplay = true
                return
            }
            document.add(Annotation(id: id, shape: shape, color: color, lineWidth: strokeWidth.lineWidth))
        case .move(let original, let from):
            document.update(original.translated(dx: point.x - from.x, dy: point.y - from.y))
        case .crop(let from):
            document.setCrop(SelectionGeometry.rect(from: from, to: point))
        }
        transient = document
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        if let transient {
            history.commit(transient)
            self.transient = nil
            historyDidChange()
        } else if case .crop = drag, history.current.crop != nil {
            // A click with the crop tool clears the crop.
            history.apply { $0.setCrop(nil) }
            historyDidChange()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            deleteSelection()
            return
        case 53: // Esc: first clears the selection, then closes the editor
            if selectedID != nil {
                selectedID = nil
                needsDisplay = true
            } else {
                onEscape?()
            }
            return
        default:
            break
        }
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
           let shortcutTool = EditorTool.allCases.first(where: { $0.key == key }) {
            onToolShortcut?(shortcutTool)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Text

    private func beginTextEditing(_ annotation: Annotation) {
        guard case .text(let string, let frame, let fontSize) = annotation.shape else { return }
        editingText = annotation
        selectedID = nil

        let field = NSTextField(string: string)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize * zoom, weight: .semibold)
        field.textColor = annotation.color.nsColor
        field.delegate = self
        field.cell?.isScrollable = true
        let origin = viewRect(frame).origin
        field.frame = CGRect(
            x: origin.x - 2,
            y: origin.y,
            width: max(frame.width * zoom + 40, 160),
            height: ceil(fontSize * zoom * 1.35)
        )
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: field.font as Any]).width
        field.frame.size.width = max(width + 40, 160)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endTextEditing()
    }

    /// Commits the text being typed (or removes the annotation when the text is now empty).
    func endTextEditing() {
        guard let field = textField, let original = editingText,
              case .text(_, let frame, let fontSize) = original.shape else { return }
        textField = nil
        editingText = nil
        field.delegate = nil
        field.removeFromSuperview()

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        history.apply { document in
            guard !text.isEmpty else {
                document.remove(id: original.id)
                return
            }
            var edited = original
            let size = AnnotationRenderer.textSize(text, fontSize: fontSize)
            edited.shape = .text(text, frame: CGRect(origin: frame.origin, size: size), fontSize: fontSize)
            if document.annotation(withID: original.id) == nil {
                document.add(edited)
            } else {
                document.update(edited)
            }
        }
        window?.makeFirstResponder(self)
        historyDidChange()
    }

    private func historyDidChange() {
        if let selectedID, history.current.annotation(withID: selectedID) == nil { self.selectedID = nil }
        needsDisplay = true
        onHistoryChange?()
    }
}
