import AppKit
import PixSnapCore
import PixSnapRender

/// A full-screen window over one display that shows the frozen screenshot and lets the user
/// drag a region or click a highlighted window.
@MainActor
final class SelectionWindow: NSWindow {
    let selectionView: SelectionView

    init(frozen: FrozenScreen, windowFrames: [CGRect]) {
        let screenFrame = frozen.screen.frame
        selectionView = SelectionView(
            frame: CGRect(origin: .zero, size: screenFrame.size),
            image: frozen.image,
            // Convert global window frames into this screen's local coordinates.
            windowRects: windowFrames.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) },
            initialMouse: NSEvent.mouseLocation.applying(.init(translationX: -screenFrame.minX, y: -screenFrame.minY))
        )
        super.init(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = selectionView
        setFrame(screenFrame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let image: NSImage
    private let frozenImage: CGImage
    private let imageSize: CGSize
    private let windowRects: [CGRect]
    private var mouse: CGPoint
    /// The magnifier only shows on the screen the cursor is on.
    private var mouseInside: Bool
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: CGRect?

    init(frame: CGRect, image: CGImage, windowRects: [CGRect], initialMouse: CGPoint) {
        self.image = NSImage(cgImage: image, size: frame.size)
        self.frozenImage = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        self.windowRects = windowRects
        self.mouse = initialMouse
        self.mouseInside = CGRect(origin: .zero, size: frame.size).contains(initialMouse)
        super.init(frame: frame)
        hoveredWindow = window(at: initialMouse)
    }

    private var pixelUnderMouse: PixelPoint {
        SelectionGeometry.pixelPoint(forViewPoint: mouse, viewSize: bounds.size, imageSize: imageSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Mouse and keyboard

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        mouseInside = true
        if dragStart == nil { hoveredWindow = window(at: mouse) }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredWindow = nil
        mouseInside = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if let dragStart {
            let rect = SelectionGeometry.rect(from: dragStart, to: mouse).intersection(bounds)
            selection = SelectionGeometry.isDrag(rect) ? rect : nil
            if selection != nil { hoveredWindow = nil }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if let selection {
            onSelect?(selection)
        } else if let hoveredWindow {
            onSelect?(hoveredWindow)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else if modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyColorUnderMouse()
        } else {
            super.keyDown(with: event)
        }
    }

    /// C copies the hex color under the cursor (as shown in the magnifier) and ends the capture.
    private func copyColorUnderMouse() {
        guard let color = MagnifierRenderer.color(at: pixelUnderMouse, in: frozenImage) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.hex, forType: .string)
        onCancel?()
    }

    private func window(at point: CGPoint) -> CGRect? {
        windowRects.first { $0.contains(point) }?.intersection(bounds)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)

        let highlight = selection ?? hoveredWindow
        let mask = NSBezierPath(rect: bounds)
        if let highlight {
            mask.append(NSBezierPath(rect: highlight))
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        mask.fill()

        if let highlight {
            let border = NSBezierPath(rect: highlight.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            border.stroke()
            drawSizeLabel(for: highlight)
        } else {
            drawCrosshair()
        }
        drawMagnifier()
    }

    private func drawMagnifier() {
        guard mouseInside, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = MagnifierRenderer.origin(forCursor: mouse, in: bounds)
        MagnifierRenderer.draw(image: frozenImage, pixel: pixelUnderMouse, at: origin, in: context)
    }

    private func drawCrosshair() {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: mouse.y))
        path.line(to: CGPoint(x: bounds.maxX, y: mouse.y))
        path.move(to: CGPoint(x: mouse.x, y: bounds.minY))
        path.line(to: CGPoint(x: mouse.x, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let pixels = SelectionGeometry.pixelRect(forViewRect: rect, viewSize: bounds.size, imageSize: imageSize)
        let text = "\(Int(pixels.width)) × \(Int(pixels.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        let labelSize = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)

        // Above the selection's top-left corner; inside it when there's no room above.
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + labelSize.height > bounds.maxY { origin.y = rect.maxY - labelSize.height - 6 }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - labelSize.width)

        let background = NSBezierPath(roundedRect: CGRect(origin: origin, size: labelSize), xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.75).setFill()
        background.fill()
        text.draw(at: CGPoint(x: origin.x + padding.width, y: origin.y + padding.height), withAttributes: attributes)
    }
}
