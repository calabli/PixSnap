import AppKit
import PixSnapCore
import PixSnapRender

/// A full-screen window over one display that shows the frozen screenshot and lets the user
/// drag a region or click a highlighted window. A dragged region stays up to be moved or resized
/// until it's confirmed (Return, a double-click, or the ✓ button).
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
            initialMouse: NSEvent.mouseLocation.applying(.init(translationX: -screenFrame.minX, y: -screenFrame.minY)),
            topInset: frozen.screen.safeAreaInsets.top
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
    /// A highlighted window was clicked: its index in the window list this view was given.
    var onSelectWindow: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    /// A new region started being drawn here: other screens drop theirs.
    var onBeginSelection: (() -> Void)?

    private let frozenImage: CGImage
    private let imageSize: CGSize
    private let windowRects: [CGRect]
    private var mouse: CGPoint
    /// The magnifier only shows on the screen the cursor is on.
    private var mouseInside: Bool
    private var drag: Drag?
    private var selection: CGRect?
    private var hoveredWindow: CGRect?

    // Full-screen parts are Core Animation layers, composited by the GPU; only the small size label
    // and magnifier are drawn by the CPU, so moving the mouse never repaints the whole screen.
    private let shapes = PassthroughView()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let crosshairX = CALayer()
    private let crosshairY = CALayer()
    private let sizeLabel = SizeLabelView()
    private let toolbar = SelectionToolbar()
    private let magnifier: MagnifierView
    /// Height of the camera notch at the top of the screen (0 without one); the size label and the
    /// magnifier stay below it so they're never hidden behind it.
    private let topInset: CGFloat

    init(frame: CGRect, image: CGImage, windowRects: [CGRect], initialMouse: CGPoint, topInset: CGFloat) {
        self.topInset = topInset
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
        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor.controlAccentColor.cgColor
        handleLayer.lineWidth = 1.5
        for line in [crosshairX, crosshairY] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
        }

        shapes.frame = bounds
        shapes.autoresizingMask = [.width, .height]
        shapes.wantsLayer = true
        shapes.layer?.addSublayer(dimLayer)
        shapes.layer?.addSublayer(borderLayer)
        shapes.layer?.addSublayer(handleLayer)
        shapes.layer?.addSublayer(crosshairX)
        shapes.layer?.addSublayer(crosshairY)
        addSubview(shapes)
        addSubview(sizeLabel)
        addSubview(magnifier)
        addSubview(toolbar)
        toolbar.onConfirm = { [weak self] in self?.confirm() }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSCursor.crosshair.set()
    }

    // MARK: Mouse and keyboard

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        mouseInside = true
        if drag == nil, selection == nil { hoveredWindow = window(at: mouse) }
        updateOverlay()
        updateCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        updateOverlay()
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        hoveredWindow = nil
        mouseInside = false
        updateOverlay()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        if let selection {
            if event.clickCount == 2, selection.contains(point) {
                confirm()
                return
            }
            if let handle = SelectionGeometry.handle(at: point, in: selection, tolerance: Self.grabTolerance) {
                drag = .resizing(handle, original: selection, from: point)
            } else if selection.contains(point) {
                drag = .moving(original: selection, from: point)
            } else {
                // Outside the selection: start over with a new one.
                self.selection = nil
                drag = .drawing(from: point)
                onBeginSelection?()
            }
        } else {
            drag = .drawing(from: point)
            onBeginSelection?()
        }
        updateOverlay()
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        switch drag {
        case .drawing(let start):
            let rect = SelectionGeometry.rect(from: start, to: mouse).intersection(bounds)
            selection = SelectionGeometry.isDrag(rect) ? rect : nil
            if selection != nil { hoveredWindow = nil }
        case .moving(let original, let start):
            selection = SelectionGeometry.moved(original, by: CGSize(width: mouse.x - start.x, height: mouse.y - start.y), within: bounds)
        case .resizing(let handle, let original, let start):
            selection = SelectionGeometry.resized(original, by: handle, delta: CGSize(width: mouse.x - start.x, height: mouse.y - start.y),
                                                  within: bounds)
        case nil:
            break
        }
        updateOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = drag else { return }
        drag = nil
        // A click without a drag takes the highlighted window straight away.
        if case .drawing = finished, selection == nil, let hoveredWindow {
            if let onSelectWindow, let index = windowRects.firstIndex(where: { $0.contains(mouse) }) {
                onSelectWindow(index)
            } else {
                onSelect?(hoveredWindow)
            }
            return
        }
        updateOverlay()
        updateCursor()
    }

    override func rightMouseDown(with event: NSEvent) {
        // A selection is dropped first, back to choosing; with none, the capture ends.
        if selection != nil, drag == nil {
            clearSelection()
        } else {
            onCancel?()
        }
    }

    /// Puts up a selection waiting to be adjusted, as if it had just been drawn (view points).
    func select(_ rect: CGRect) {
        selection = rect.intersection(bounds)
        hoveredWindow = nil
        updateOverlay()
    }

    /// Drops the selection, as when another screen starts one.
    func clearSelection() {
        selection = nil
        drag = nil
        hoveredWindow = mouseInside ? window(at: mouse) : nil
        updateOverlay()
        updateCursor()
    }

    private func confirm() {
        guard let selection, drag == nil else { return }
        onSelect?(selection)
    }

    /// Arrow keys nudge the selection a point at a time, ten with Shift.
    private func nudge(_ keyCode: UInt16, fast: Bool) -> Bool {
        let step: CGFloat = fast ? 10 : 1
        let delta: CGSize
        switch keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: -step)
        case 126: delta = CGSize(width: 0, height: step)
        default: return false
        }
        guard let selection, drag == nil else { return true }
        self.selection = SelectionGeometry.moved(selection, by: delta, within: bounds)
        updateOverlay()
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else if event.keyCode == 36 || event.keyCode == 76 { // Return, Enter
            confirm()
        } else if modifiers.subtracting(.shift).isEmpty, nudge(event.keyCode, fast: modifiers.contains(.shift)) {
            return
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

    /// How far from an edge (in points) it can still be grabbed.
    private static let grabTolerance: CGFloat = 6
    private static let handleSize: CGFloat = 7

    private enum Drag {
        case drawing(from: CGPoint)
        case moving(original: CGRect, from: CGPoint)
        case resizing(SelectionHandle, original: CGRect, from: CGPoint)
    }

    /// Crosshair to draw, a hand over the selection to move it, arrows on its edges to resize it.
    private func updateCursor() {
        let cursor: NSCursor
        switch drag {
        case .drawing: cursor = .crosshair
        case .moving: cursor = .closedHand
        case .resizing(let handle, _, _): cursor = Self.cursor(for: handle)
        case nil:
            if !toolbar.isHidden, toolbar.frame.contains(mouse) {
                cursor = .arrow
            } else if let selection, let handle = SelectionGeometry.handle(at: mouse, in: selection, tolerance: Self.grabTolerance) {
                cursor = Self.cursor(for: handle)
            } else if let selection, selection.contains(mouse) {
                cursor = .openHand
            } else {
                cursor = .crosshair
            }
        }
        cursor.set()
    }

    private static func cursor(for handle: SelectionHandle) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case .bottomLeft: .bottomLeft
            case .bottom: .bottom
            case .bottomRight: .bottomRight
            case .right: .right
            case .topRight: .topRight
            case .top: .top
            case .topLeft: .topLeft
            case .left: .left
            }
            return .frameResize(position: position, directions: .all)
        }
        if handle.vertical == 0 { return .resizeLeftRight }
        if handle.horizontal == 0 { return .resizeUpDown }
        return .crosshair
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

        handleLayer.isHidden = selection == nil
        if let selection {
            let handles = CGMutablePath()
            let size = Self.handleSize
            for handle in SelectionHandle.allCases {
                let point = handle.point(on: selection)
                handles.addRect(CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            }
            handleLayer.frame = bounds
            handleLayer.path = handles
        }

        sizeLabel.isHidden = highlight == nil
        if let highlight { placeSizeLabel(for: highlight) }

        // The ✓ / ✕ buttons wait under a selection that's been let go.
        toolbar.isHidden = selection == nil || drag != nil
        if let selection, drag == nil { placeToolbar(for: selection) }

        // While a selection is waiting, the loupe only comes back for dragging its edges.
        let showsMagnifier = mouseInside && (selection == nil || drag != nil)
        magnifier.isHidden = !showsMagnifier
        if showsMagnifier {
            magnifier.setFrameOrigin(MagnifierRenderer.origin(forCursor: mouse, in: labelBounds))
            magnifier.pixel = pixelUnderMouse
        }
    }

    private func placeSizeLabel(for rect: CGRect) {
        let pixels = SelectionGeometry.pixelRect(forViewRect: rect, viewSize: bounds.size, imageSize: imageSize)
        sizeLabel.text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        let size = sizeLabel.fittingSize

        // Above the selection's top-left corner; inside it when there's no room above.
        let area = labelBounds
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height > area.maxY { origin.y = min(rect.maxY, area.maxY) - size.height - 6 }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        sizeLabel.frame = CGRect(origin: origin, size: size)
    }

    /// Below the selection's bottom-right corner; above it, or inside it, when there's no room.
    private func placeToolbar(for rect: CGRect) {
        let size = toolbar.fittingSize
        let area = labelBounds
        var origin = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 8)
        if origin.y < area.minY {
            origin.y = rect.maxY + 8 + size.height <= area.maxY ? rect.maxY + 8 : rect.minY + 8
        }
        origin.x = min(max(origin.x, area.minX + 4), area.maxX - size.width - 4)
        toolbar.frame = CGRect(origin: origin, size: size)
    }

    /// Where the size label and magnifier may go: the screen minus the notch strip at the top.
    private var labelBounds: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - topInset)
    }
}

/// A view that never takes mouse events, so clicks reach the selection view underneath.
private class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// ✕ and ✓ under a selection that's waiting to be confirmed.
@MainActor
private final class SelectionToolbar: NSVisualEffectView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.addArrangedSubview(button(symbol: "xmark", tip: "取消（Esc）", action: #selector(cancel)))
        let done = button(symbol: "checkmark", tip: "完成截图（回车，或双击选区）", action: #selector(confirm))
        done.contentTintColor = .controlAccentColor
        stack.addArrangedSubview(done)
        stack.frame = CGRect(origin: .zero, size: stack.fittingSize)
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var fittingSize: NSSize { stack.fittingSize }

    private func button(symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))!
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func confirm() { onConfirm?() }
    @objc private func cancel() { onCancel?() }
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
