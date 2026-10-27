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

        // The frozen screenshot is the background layer's contents, so the GPU composites it; the
        // selection view on top only redraws the mask, selection and magnifier as the mouse moves.
        let background = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        background.wantsLayer = true
        background.layer?.contents = frozen.image
        background.layer?.contentsGravity = .resize
        selectionView.autoresizingMask = [.width, .height]
        background.addSubview(selectionView)
        contentView = background
        setFrame(screenFrame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let frozenImage: CGImage
    private let imageSize: CGSize
    private let windowRects: [CGRect]
    private var mouse: CGPoint
    /// The magnifier only shows on the screen the cursor is on.
    private var mouseInside: Bool
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: CGRect?

    // Full-screen parts are Core Animation layers, composited by the GPU; only the small size label
    // and magnifier are drawn by the CPU, so moving the mouse never repaints the whole screen.
    private let shapes = PassthroughView()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let crosshairX = CALayer()
    private let crosshairY = CALayer()
    private let sizeLabel = SizeLabelView()
    private let magnifier: MagnifierView

    init(frame: CGRect, image: CGImage, windowRects: [CGRect], initialMouse: CGPoint) {
        self.frozenImage = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        self.windowRects = windowRects
        self.mouse = initialMouse
        self.mouseInside = CGRect(origin: .zero, size: frame.size).contains(initialMouse)
        self.magnifier = MagnifierView(image: image)
        super.init(frame: frame)
        hoveredWindow = window(at: initialMouse)

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.controlAccentColor.cgColor
        borderLayer.lineWidth = 1.5
        for line in [crosshairX, crosshairY] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
        }

        shapes.frame = bounds
        shapes.autoresizingMask = [.width, .height]
        shapes.wantsLayer = true
        shapes.layer?.addSublayer(dimLayer)
        shapes.layer?.addSublayer(borderLayer)
        shapes.layer?.addSublayer(crosshairX)
        shapes.layer?.addSublayer(crosshairY)
        addSubview(shapes)
        addSubview(sizeLabel)
        addSubview(magnifier)
        updateOverlay()
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
        updateOverlay()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        updateOverlay()
    }

    override func mouseExited(with event: NSEvent) {
        hoveredWindow = nil
        mouseInside = false
        updateOverlay()
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
        updateOverlay()
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


    // MARK: Overlay

    /// Moves the layers and small views to match the current mouse, hover and selection.
    private func updateOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let highlight = selection ?? hoveredWindow
        let mask = CGMutablePath()
        mask.addRect(bounds)
        if let highlight { mask.addRect(highlight) }
        dimLayer.frame = bounds
        dimLayer.path = mask

        borderLayer.isHidden = highlight == nil
        if let highlight {
            borderLayer.frame = bounds
            borderLayer.path = CGPath(rect: highlight.insetBy(dx: -0.75, dy: -0.75), transform: nil)
        }

        let showsCrosshair = highlight == nil && mouseInside
        crosshairX.isHidden = !showsCrosshair
        crosshairY.isHidden = !showsCrosshair
        if showsCrosshair {
            crosshairX.frame = CGRect(x: bounds.minX, y: mouse.y.rounded(.down), width: bounds.width, height: 1)
            crosshairY.frame = CGRect(x: mouse.x.rounded(.down), y: bounds.minY, width: 1, height: bounds.height)
        }

        sizeLabel.isHidden = highlight == nil
        if let highlight { placeSizeLabel(for: highlight) }

        magnifier.isHidden = !mouseInside
        if mouseInside {
            magnifier.setFrameOrigin(MagnifierRenderer.origin(forCursor: mouse, in: bounds))
            magnifier.pixel = pixelUnderMouse
        }
    }

    private func placeSizeLabel(for rect: CGRect) {
        let pixels = SelectionGeometry.pixelRect(forViewRect: rect, viewSize: bounds.size, imageSize: imageSize)
        sizeLabel.text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        let size = sizeLabel.fittingSize

        // Above the selection's top-left corner; inside it when there's no room above.
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height > bounds.maxY { origin.y = rect.maxY - size.height - 6 }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        sizeLabel.frame = CGRect(origin: origin, size: size)
    }
}

/// A view that never takes mouse events, so clicks reach the selection view underneath.
private class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "1280 × 720" above the selection.
@MainActor
private final class SizeLabelView: PassthroughView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    private static let padding = CGSize(width: 8, height: 4)

    override var fittingSize: NSSize {
        let textSize = (text as NSString).size(withAttributes: Self.attributes)
        return CGSize(width: ceil(textSize.width + Self.padding.width * 2), height: ceil(textSize.height + Self.padding.height * 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: Self.padding.width, y: Self.padding.height), withAttributes: Self.attributes)
    }
}

/// The loupe next to the cursor; redraws only its own small area.
@MainActor
private final class MagnifierView: PassthroughView {
    var pixel = PixelPoint(x: 0, y: 0) {
        didSet { if pixel != oldValue { needsDisplay = true } }
    }

    private let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: MagnifierRenderer.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        MagnifierRenderer.draw(image: image, pixel: pixel, at: .zero, in: context)
    }
}
